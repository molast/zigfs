package main

import (
	"bytes"
	"fmt"
	"sync"
	"testing"
)

func TestAdapters(t *testing.T) {
	for _, name := range []string{"bbolt", "bbolt-batch", "pebble", "badger"} {
		t.Run(name, func(t *testing.T) {
			path := t.TempDir()
			db, err := openStore(name, path)
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				if db != nil {
					db.Close()
				}
			}()
			records := make([]record, 20)
			for i := range records {
				records[i] = record{keyFor(i), []byte("initial")}
			}
			if err := db.Put(records, true); err != nil {
				t.Fatal(err)
			}
			// A failed initial batch must not publish the preceding new key.
			if err := db.Put([]record{{[]byte("new"), []byte("bad")}, records[0]}, true); err == nil {
				t.Fatal("missing conflict")
			}
			if _, err := db.Get([]byte("new")); err == nil {
				t.Fatal("partial rejected batch")
			}
			owned, err := db.Get(records[0].Key)
			if err != nil {
				t.Fatal(err)
			}
			owned.Value[0] = 'X'
			unchanged, err := db.Get(records[0].Key)
			if err != nil || !bytes.Equal(unchanged.Value, []byte("initial")) {
				t.Fatal("borrowed result escaped")
			}
			var wg sync.WaitGroup
			for worker := 0; worker < 4; worker++ {
				wg.Go(func() {
					for i := worker; i < 20; i += 4 {
						if err := db.Put([]record{{keyFor(i), []byte(fmt.Sprintf("value-%d", i))}}, false); err != nil {
							t.Error(err)
						}
					}
				})
			}
			wg.Wait()
			if err := db.Close(); err != nil {
				t.Fatal(err)
			}
			db = nil
			db, err = openStore(name, path)
			if err != nil {
				t.Fatal(err)
			}
			var after []byte
			count := 0
			for {
				page, more, err := db.Scan(prefix, after, 7)
				if err != nil {
					t.Fatal(err)
				}
				for _, r := range page {
					if !bytes.Equal(r.Key, keyFor(count)) || !bytes.Equal(r.Value, []byte(fmt.Sprintf("value-%d", count))) {
						t.Fatalf("bad record %d", count)
					}
					count++
				}
				if !more {
					break
				}
				if len(page) == 0 {
					t.Fatal("no cursor progress")
				}
				after = page[len(page)-1].Key
			}
			if count != 20 {
				t.Fatalf("count %d", count)
			}
		})
	}
}
