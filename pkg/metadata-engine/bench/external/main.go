package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/cockroachdb/pebble"
	"github.com/dgraph-io/badger/v4"
	"github.com/dgraph-io/badger/v4/options"
	bolt "go.etcd.io/bbolt"
)

type record struct{ Key, Value []byte }
type store interface {
	Put([]record, bool) error
	Get([]byte) (record, error)
	Scan([]byte, []byte, int) ([]record, bool, error)
	Close() error
}

var bucket = []byte("object")
var prefix = []byte("bucket/key-")
var conflict = errors.New("key already exists")

// Each returned record owns its bytes after the read transaction/iterator closes.
func copied(key, value []byte) record { return record{bytes.Clone(key), bytes.Clone(value)} }
func eligible(key, after []byte) bool { return after == nil || bytes.Compare(key, after) > 0 }

type boltStore struct {
	db    *bolt.DB
	group bool
}

func (s *boltStore) Close() error { return s.db.Close() }
func (s *boltStore) Put(records []record, missing bool) error {
	commit := s.db.Update
	if s.group && !missing {
		commit = s.db.Batch
	}
	return commit(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucket)
		for _, r := range records {
			if missing && b.Get(r.Key) != nil {
				return conflict
			}
			if err := b.Put(r.Key, r.Value); err != nil {
				return err
			}
		}
		return nil
	})
}
func (s *boltStore) Get(key []byte) (out record, err error) {
	err = s.db.View(func(tx *bolt.Tx) error {
		value := tx.Bucket(bucket).Get(key)
		if value == nil {
			return errors.New("not found")
		}
		out = copied(key, value)
		return nil
	})
	return
}
func (s *boltStore) Scan(start, after []byte, limit int) (out []record, more bool, err error) {
	err = s.db.View(func(tx *bolt.Tx) error {
		cursor := tx.Bucket(bucket).Cursor()
		seek := start
		if bytes.Compare(after, seek) > 0 {
			seek = after
		}
		for k, v := cursor.Seek(seek); k != nil && bytes.HasPrefix(k, start); k, v = cursor.Next() {
			if !eligible(k, after) {
				continue
			}
			if limit > 0 && len(out) == limit {
				more = true
				break
			}
			out = append(out, copied(k, v))
		}
		return nil
	})
	return
}

type pebbleStore struct{ db *pebble.DB }

func (s *pebbleStore) Close() error { return s.db.Close() }
func (s *pebbleStore) Put(records []record, missing bool) error {
	batch := s.db.NewBatch()
	defer batch.Close()
	for _, r := range records {
		// Initial inserts have one writer; this check is not a general concurrent CAS.
		if missing {
			_, closer, err := s.db.Get(r.Key)
			if err == nil {
				closer.Close()
				return conflict
			}
			if !errors.Is(err, pebble.ErrNotFound) {
				return err
			}
		}
		if err := batch.Set(r.Key, r.Value, nil); err != nil {
			return err
		}
	}
	return batch.Commit(pebble.Sync)
}
func (s *pebbleStore) Get(key []byte) (record, error) {
	value, closer, err := s.db.Get(key)
	if err != nil {
		return record{}, err
	}
	defer closer.Close()
	return copied(key, value), nil
}
func (s *pebbleStore) Scan(start, after []byte, limit int) ([]record, bool, error) {
	iter, err := s.db.NewIter(&pebble.IterOptions{LowerBound: start})
	if err != nil {
		return nil, false, err
	}
	defer iter.Close()
	seek := start
	if bytes.Compare(after, seek) > 0 {
		seek = after
	}
	var out []record
	more := false
	for valid := iter.SeekGE(seek); valid && bytes.HasPrefix(iter.Key(), start); valid = iter.Next() {
		if !eligible(iter.Key(), after) {
			continue
		}
		if limit > 0 && len(out) == limit {
			more = true
			break
		}
		out = append(out, copied(iter.Key(), iter.Value()))
	}
	return out, more, iter.Error()
}

type badgerStore struct{ db *badger.DB }

func (s *badgerStore) Close() error { return s.db.Close() }
func (s *badgerStore) Put(records []record, missing bool) error {
	return s.db.Update(func(tx *badger.Txn) error {
		for _, r := range records {
			if missing {
				_, err := tx.Get(r.Key)
				if err == nil {
					return conflict
				}
				if !errors.Is(err, badger.ErrKeyNotFound) {
					return err
				}
			}
			if err := tx.Set(r.Key, r.Value); err != nil {
				return err
			}
		}
		return nil
	})
}
func (s *badgerStore) Get(key []byte) (out record, err error) {
	err = s.db.View(func(tx *badger.Txn) error {
		item, err := tx.Get(key)
		if err != nil {
			return err
		}
		value, err := item.ValueCopy(nil)
		if err != nil {
			return err
		}
		out = record{bytes.Clone(key), value}
		return nil
	})
	return
}
func (s *badgerStore) Scan(start, after []byte, limit int) (out []record, more bool, err error) {
	err = s.db.View(func(tx *badger.Txn) error {
		opts := badger.DefaultIteratorOptions
		opts.Prefix = start
		iter := tx.NewIterator(opts)
		defer iter.Close()
		seek := start
		if bytes.Compare(after, seek) > 0 {
			seek = after
		}
		for iter.Seek(seek); iter.ValidForPrefix(start); iter.Next() {
			item := iter.Item()
			if !eligible(item.Key(), after) {
				continue
			}
			if limit > 0 && len(out) == limit {
				more = true
				break
			}
			value, err := item.ValueCopy(nil)
			if err != nil {
				return err
			}
			out = append(out, record{item.KeyCopy(nil), value})
		}
		return nil
	})
	return
}

func openStore(name, path string) (store, error) {
	switch name {
	case "bbolt", "bbolt-batch":
		db, err := bolt.Open(filepath.Join(path, "data.db"), 0600, &bolt.Options{Timeout: time.Second})
		if err != nil {
			return nil, err
		}
		// Namespace creation only on first open; no extra write transaction on reopen.
		exists := false
		err = db.View(func(tx *bolt.Tx) error { exists = tx.Bucket(bucket) != nil; return nil })
		if err == nil && !exists {
			err = db.Update(func(tx *bolt.Tx) error { _, err := tx.CreateBucket(bucket); return err })
		}
		if err != nil {
			db.Close()
			return nil, err
		}
		db.MaxBatchSize = 64
		db.MaxBatchDelay = 100 * time.Microsecond
		return &boltStore{db: db, group: name == "bbolt-batch"}, nil
	case "pebble":
		opts := (&pebble.Options{}).EnsureDefaults()
		for i := range opts.Levels {
			opts.Levels[i].Compression = pebble.NoCompression
		}
		db, err := pebble.Open(path, opts)
		if err != nil {
			return nil, err
		}
		return &pebbleStore{db}, nil
	case "badger":
		opts := badger.DefaultOptions(path).WithSyncWrites(true).WithCompression(options.None).WithLogger(nil)
		db, err := badger.Open(opts)
		if err != nil {
			return nil, err
		}
		return &badgerStore{db}, nil
	default:
		return nil, fmt.Errorf("unknown engine %q", name)
	}
}

type metric struct {
	Operations   int     `json:"operations"`
	Transactions int     `json:"transactions"`
	QPS          float64 `json:"qps"`
	TPS          float64 `json:"tps"`
	P50          float64 `json:"p50_us"`
	P95          float64 `json:"p95_us"`
	P99          float64 `json:"p99_us"`
	Max          float64 `json:"max_us"`
	Elapsed      float64 `json:"elapsed_ms"`
}

func summarize(operations int, elapsed time.Duration, timings []time.Duration) metric {
	sort.Slice(timings, func(i, j int) bool { return timings[i] < timings[j] })
	percentile := func(percent int) float64 { return float64(timings[(len(timings)*percent-1)/100]) / 1000 }
	return metric{operations, len(timings), float64(operations) / elapsed.Seconds(),
		float64(len(timings)) / elapsed.Seconds(), percentile(50), percentile(95), percentile(99),
		percentile(100), float64(elapsed) / 1e6}
}
func keyFor(index int) []byte { return []byte(fmt.Sprintf("bucket/key-%012d", index)) }
func run(name, path string, count, payloadSize, batchSize, workers int) error {
	if err := os.Mkdir(path, 0700); err != nil {
		return err
	}
	db, err := openStore(name, path)
	if err != nil {
		return err
	}
	defer func() {
		if db != nil {
			db.Close()
		}
	}()
	metrics := make(map[string]metric)
	payload := bytes.Repeat([]byte{'x'}, payloadSize)
	timings := make([]time.Duration, count)
	transactions := 0
	start := time.Now()
	for offset := 0; offset < count; {
		size := min(batchSize, count-offset)
		records := make([]record, size)
		for i := range records {
			records[i] = record{keyFor(offset + i), payload}
		}
		before := time.Now()
		if err := db.Put(records, true); err != nil {
			return err
		}
		timings[transactions] = time.Since(before)
		transactions++
		offset += size
	}
	metrics["durable_insert"] = summarize(count, time.Since(start), timings[:transactions])
	start = time.Now()
	for i := 0; i < count; i++ {
		key := keyFor(i)
		before := time.Now()
		r, err := db.Get(key)
		if err != nil {
			return err
		}
		if !bytes.Equal(r.Value, payload) {
			return errors.New("get validation failed")
		}
		timings[i] = time.Since(before)
	}
	metrics["warm_get"] = summarize(count, time.Since(start), timings)
	payload = bytes.Repeat([]byte{'y'}, payloadSize)
	var wg sync.WaitGroup
	failures := make(chan error, workers)
	start = time.Now()
	for worker := 0; worker < workers; worker++ {
		wg.Go(func() {
			for i := worker; i < count; i += workers {
				key := keyFor(i)
				before := time.Now()
				if err := db.Put([]record{{key, payload}}, false); err != nil {
					failures <- err
					return
				}
				timings[i] = time.Since(before)
			}
		})
	}
	wg.Wait()
	elapsed := time.Since(start)
	close(failures)
	for err := range failures {
		return err
	}
	metrics["concurrent_overwrite"] = summarize(count, elapsed, timings)
	start = time.Now()
	var cursor []byte
	listed, pages := 0, 0
	for {
		records, more, err := db.Scan(prefix, cursor, 100)
		if err != nil {
			return err
		}
		listed += len(records)
		pages++
		if !more {
			break
		}
		if len(records) == 0 {
			return errors.New("pagination stalled")
		}
		cursor = records[len(records)-1].Key
	}
	if listed != count {
		return fmt.Errorf("page count: %d != %d", listed, count)
	}
	metrics["prefix_pages"] = metric{Operations: listed, Transactions: pages, Elapsed: float64(time.Since(start)) / 1e6}
	start = time.Now()
	records, _, err := db.Scan(nil, nil, 0)
	if err != nil {
		return err
	}
	if len(records) != count {
		return errors.New("scan count mismatch")
	}
	metrics["full_sorted_scan"] = metric{Operations: len(records), Elapsed: float64(time.Since(start)) / 1e6}
	records = nil
	start = time.Now()
	if err := db.Close(); err != nil {
		return err
	}
	db = nil
	metrics["close"] = metric{Elapsed: float64(time.Since(start)) / 1e6}
	start = time.Now()
	db, err = openStore(name, path)
	if err != nil {
		return err
	}
	metrics["reopen"] = metric{Elapsed: float64(time.Since(start)) / 1e6}
	records, _, err = db.Scan(nil, nil, 0)
	if err != nil {
		return err
	}
	if len(records) != count {
		return errors.New("reopen count mismatch")
	}
	for i, r := range records {
		if !bytes.Equal(r.Key, keyFor(i)) || !bytes.Equal(r.Value, payload) {
			return fmt.Errorf("reopen validation at %d", i)
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"engine": name, "go": runtime.Version(), "gomaxprocs": runtime.GOMAXPROCS(0),
		"operations": count, "payload_bytes": payloadSize, "batch_size": batchSize, "workers": workers,
		"metrics": metrics, "verified": true,
	})
}
func main() {
	if len(os.Args) != 7 {
		fmt.Fprintln(os.Stderr, "usage: kvbench ENGINE NEW_DIR RECORDS PAYLOAD BATCH WORKERS")
		os.Exit(2)
	}
	values := make([]int, 4)
	for i := range values {
		v, err := strconv.Atoi(os.Args[i+3])
		if err != nil || v < 1 {
			fmt.Fprintln(os.Stderr, "arguments must be positive integers")
			os.Exit(2)
		}
		values[i] = v
	}
	if err := run(os.Args[1], os.Args[2], values[0], values[1], values[2], values[3]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
