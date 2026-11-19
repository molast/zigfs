package gateway

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"time"
)

func serialNumber() (*big.Int, error) {
	return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
}

func newCA(now time.Time) (*Material, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := serialNumber()
	if err != nil {
		return nil, err
	}
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "ZigFS Local CA"},
		NotBefore: now.Add(-5 * time.Minute), NotAfter: now.AddDate(5, 0, 0),
		IsCA: true, BasicConstraintsValid: true, MaxPathLen: 0, MaxPathLenZero: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	material, err := signMaterial(template, template, key, key)
	return &material, err
}

func signMaterial(template, parent *x509.Certificate, key, signer *ecdsa.PrivateKey) (Material, error) {
	der, err := x509.CreateCertificate(rand.Reader, template, parent, &key.PublicKey, signer)
	if err != nil {
		return Material{}, err
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return Material{}, err
	}
	return Material{
		Certificate: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})),
		Key:         string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})),
	}, nil
}

func issueCertificate(c Config, ca Material, now time.Time) (Material, error) {
	pair, err := tls.X509KeyPair([]byte(ca.Certificate), []byte(ca.Key))
	if err != nil {
		return Material{}, err
	}
	parent, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return Material{}, err
	}
	signer, ok := pair.PrivateKey.(*ecdsa.PrivateKey)
	if !ok || !parent.IsCA || now.Before(parent.NotBefore) || !parent.NotAfter.After(now.Add(30*24*time.Hour)) {
		return Material{}, errors.New("local CA requires maintenance; it will not be replaced automatically")
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return Material{}, err
	}
	serial, err := serialNumber()
	if err != nil {
		return Material{}, err
	}
	expiry := now.Add(90 * 24 * time.Hour)
	if expiry.After(parent.NotAfter) {
		expiry = parent.NotAfter
	}
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: c.AdminDomain},
		DNSNames: []string{c.AdminDomain, c.S3Domain}, NotBefore: now.Add(-5 * time.Minute), NotAfter: expiry,
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	return signMaterial(template, parent, key, signer)
}

func validateCertificate(c Config, material Material, now time.Time) (*tls.Certificate, error) {
	if len(material.Certificate) > 128*1024 || len(material.Key) > 32*1024 {
		return nil, errors.New("certificate or key too large")
	}
	pair, err := tls.X509KeyPair([]byte(material.Certificate), []byte(material.Key))
	if err != nil {
		return nil, errors.New("invalid certificate chain or mismatched private key")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, err
	}
	if leaf.IsCA || now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
		return nil, errors.New("server certificate is not currently valid")
	}
	if err := leaf.VerifyHostname(c.AdminDomain); err != nil {
		return nil, err
	}
	if err := leaf.VerifyHostname(c.S3Domain); err != nil {
		return nil, err
	}
	if len(leaf.ExtKeyUsage) > 0 {
		allowed := false
		for _, usage := range leaf.ExtKeyUsage {
			if usage == x509.ExtKeyUsageServerAuth || usage == x509.ExtKeyUsageAny {
				allowed = true
			}
		}
		if !allowed {
			return nil, errors.New("certificate does not allow server authentication")
		}
	}
	// Validate order and signatures of supplied intermediates. Trust in the root
	// remains a client decision; importing a private CA is supported.
	for i := 1; i < len(pair.Certificate); i++ {
		child, e := x509.ParseCertificate(pair.Certificate[i-1])
		if e != nil {
			return nil, e
		}
		parent, e := x509.ParseCertificate(pair.Certificate[i])
		if e != nil {
			return nil, e
		}
		if e = child.CheckSignatureFrom(parent); e != nil {
			return nil, e
		}
		if now.Before(parent.NotBefore) || !now.Before(parent.NotAfter) {
			return nil, errors.New("certificate chain is expired or not yet valid")
		}
	}
	pair.Leaf = leaf
	return &pair, nil
}

func fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}
