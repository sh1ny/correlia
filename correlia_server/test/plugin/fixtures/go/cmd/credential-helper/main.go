package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

type credentialOutput struct {
	Certificate string `json:"certificate"`
	PrivateKey  string `json:"private_key"`
}

func main() {
	outputDirectory := flag.String("output-dir", "", "owner-only output directory")
	flag.Parse()
	if flag.NArg() != 0 {
		fail(errors.New("unexpected positional arguments"))
	}
	if *outputDirectory == "" {
		fail(errors.New("--output-dir is required"))
	}
	if err := generate(*outputDirectory); err != nil {
		fail(err)
	}
}

func generate(outputDirectory string) error {
	if err := os.MkdirAll(outputDirectory, 0o700); err != nil {
		return fmt.Errorf("create credential directory: %w", err)
	}
	if err := os.Chmod(outputDirectory, 0o700); err != nil {
		return fmt.Errorf("restrict credential directory: %w", err)
	}

	key, err := ecdsa.GenerateKey(elliptic.P521(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate P-521 key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return fmt.Errorf("generate certificate serial: %w", err)
	}

	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "localhost",
			Organization: []string{"Correlia Plugin Spike"},
		},
		DNSNames:              []string{"localhost"},
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		NotBefore:             now.Add(-30 * time.Second),
		NotAfter:              now.Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(
		rand.Reader,
		template,
		template,
		key.Public(),
		key,
	)
	if err != nil {
		return fmt.Errorf("create P-521 certificate: %w", err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return fmt.Errorf("marshal P-521 private key: %w", err)
	}

	certificatePath := filepath.Join(outputDirectory, "client-certificate.pem")
	privateKeyPath := filepath.Join(outputDirectory, "client-private-key.pem")
	manifestPath := filepath.Join(outputDirectory, "credentials.json")
	if err := writePrivateFile(
		certificatePath,
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
	); err != nil {
		return err
	}
	if err := writePrivateFile(
		privateKeyPath,
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}),
	); err != nil {
		return err
	}
	manifest, err := json.Marshal(credentialOutput{
		Certificate: certificatePath,
		PrivateKey:  privateKeyPath,
	})
	if err != nil {
		return fmt.Errorf("encode credential manifest: %w", err)
	}
	if err := writePrivateFile(manifestPath, append(manifest, '\n')); err != nil {
		return err
	}

	fmt.Println(manifestPath)
	return nil
}

func writePrivateFile(path string, contents []byte) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("open %s: %w", filepath.Base(path), err)
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return fmt.Errorf("restrict %s: %w", filepath.Base(path), err)
	}
	if _, err := file.Write(contents); err != nil {
		_ = file.Close()
		return fmt.Errorf("write %s: %w", filepath.Base(path), err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return fmt.Errorf("sync %s: %w", filepath.Base(path), err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close %s: %w", filepath.Base(path), err)
	}
	return nil
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
