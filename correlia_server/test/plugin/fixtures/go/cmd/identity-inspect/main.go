// identity-inspect independently checks a PEM identity supplied over stdin.
package main

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"os"
	"time"
)

func main() {
	var input struct { Certificate string `json:"certificate"`; Key string `json:"key"` }
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil { panic(err) }
	certBlock, _ := pem.Decode([]byte(input.Certificate))
	keyBlock, _ := pem.Decode([]byte(input.Key))
	if certBlock == nil || keyBlock == nil { panic("missing PEM") }
	cert, err := x509.ParseCertificate(certBlock.Bytes); if err != nil { panic(err) }
	keyAny, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes); if err != nil { panic(err) }
	key, ok := keyAny.(*ecdsa.PrivateKey); if !ok { panic("not an EC key") }
	public, ok := cert.PublicKey.(*ecdsa.PublicKey); if !ok { panic("not an EC certificate") }
	validity := cert.NotAfter.Sub(cert.NotBefore)
	if key.Curve.Params().Name != "P-521" || public.Curve.Params().Name != "P-521" || !public.Equal(&key.PublicKey) ||
		cert.SignatureAlgorithm != x509.ECDSAWithSHA512 || cert.CheckSignature(cert.SignatureAlgorithm, cert.RawTBSCertificate, cert.Signature) != nil ||
		len(cert.DNSNames) != 1 || cert.DNSNames[0] != "localhost" || validity != 30*24*time.Hour ||
		time.Now().Before(cert.NotBefore) || time.Now().After(cert.NotAfter) {
		fmt.Fprintln(os.Stderr, "identity validation failed")
		os.Exit(1)
	}
	fmt.Println("valid")
}
