// native-tls-peer is an isolated byte-stream peer for transport ownership tests.
package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	path := flag.String("socket", "", "Unix socket path")
	clientCert := flag.String("client-cert", "", "trusted client certificate PEM")
	mode := flag.String("mode", "echo", "echo, send, settings-stall or tls-stall")
	flag.Parse()
	if *path == "" || *clientCert == "" || flag.NArg() != 0 {
		return errors.New("socket and client-cert are required")
	}
	key, err := ecdsa.GenerateKey(elliptic.P521(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "localhost"},
		DNSNames: []string{"localhost"}, NotBefore: now.Add(-time.Minute),
		NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IsCA:        true, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return err
	}
	trusted, err := os.ReadFile(*clientCert)
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(trusted) {
		return errors.New("invalid client certificate")
	}
	listener, err := net.Listen("unix", *path)
	if err != nil {
		return err
	}
	defer listener.Close()
	fmt.Println(base64.StdEncoding.EncodeToString(der))
	raw, err := listener.Accept()
	if err != nil {
		return err
	}
	defer raw.Close()
	if unix, ok := raw.(*net.UnixConn); ok {
		if err := unix.SetReadBuffer(4096); err != nil {
			return err
		}
		if err := unix.SetWriteBuffer(4096); err != nil {
			return err
		}
	}
	control := bufio.NewReader(os.Stdin)
	if *mode == "tls-stall" {
		fmt.Println("accepted")
		_, err = io.Copy(io.Discard, raw)
		fmt.Println("closed")
		return err
	}
	conn := tls.Server(raw, &tls.Config{
		MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: roots, NextProtos: []string{"h2"},
	})
	if err := conn.Handshake(); err != nil {
		return err
	}
	fmt.Println("authenticated")
	if *mode == "settings-stall" {
		_, err = io.Copy(io.Discard, conn)
		fmt.Println("closed")
		return err
	}
	// Wait for a test-controlled barrier before reading or writing application data.
	if _, err = control.ReadString('\n'); err != nil {
		return err
	}
	switch *mode {
	case "echo":
		fmt.Println("reading")
		_, err = io.Copy(conn, conn)
	case "send":
		fmt.Println("sending")
		buf := make([]byte, 16*1024)
		for offset := 0; offset < 8*1024*1024; offset += len(buf) {
			for i := range buf {
				buf[i] = byte(((offset+i)*31 + (offset+i)/251) % 256)
			}
			if _, err = conn.Write(buf); err != nil {
				return err
			}
		}
		fmt.Println("sent")
		// Keep the connection alive until the client has consumed the bytes.
		_, err = control.ReadString('\n')
	default:
		return errors.New("unknown peer mode")
	}
	return err
}
