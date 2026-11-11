package fixture

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
)

// MaxJournalBytes bounds the acceptance journal for one test run.
const MaxJournalBytes int64 = 32 * 1024 * 1024

// JournalRecord is one immutable event accepted by the fixture.
type JournalRecord struct {
	ID       string `json:"id"`
	SHA256   string `json:"sha256"`
	Epoch    string `json:"epoch"`
	Sequence uint64 `json:"sequence"`
}

// Journal is an append-only, size-bounded acceptance journal.
//
// Records are newline-delimited JSON. A batch is written as one buffered
// write, then the file is synced before the receiver acknowledges it. The
// receiver can therefore reject a trailing torn line while preserving all
// complete earlier records.
type Journal struct {
	mu       sync.Mutex
	file     *os.File
	writer   *bufio.Writer
	bytes    int64
	closed   bool
	maxBytes int64
}

// OpenJournal opens or creates an owner-only acceptance journal.
func OpenJournal(path string) (*Journal, error) {
	if path == "" {
		return nil, errors.New("journal path is required")
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|os.O_APPEND, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open journal: %w", err)
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("restrict journal permissions: %w", err)
	}

	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("stat journal: %w", err)
	}
	if info.Size() > MaxJournalBytes {
		_ = file.Close()
		return nil, fmt.Errorf("journal exceeds %d-byte bound", MaxJournalBytes)
	}

	return &Journal{
		file:     file,
		writer:   bufio.NewWriter(file),
		bytes:    info.Size(),
		maxBytes: MaxJournalBytes,
	}, nil
}

// AppendBatch durably appends all events in a batch.
//
// The caller must not acknowledge the batch until AppendBatch returns
// successfully. The entire batch is serialized before any byte is written,
// so a size failure leaves the journal unchanged.
func (journal *Journal) AppendBatch(epoch string, sequence uint64, events []EventPayload) error {
	journal.mu.Lock()
	defer journal.mu.Unlock()

	if journal.closed {
		return errors.New("journal is closed")
	}

	encoded := make([]byte, 0, len(events)*160)
	for _, event := range events {
		digest := sha256.Sum256(event.CanonicalJSON)
		record := JournalRecord{
			ID:       event.ID,
			SHA256:   hex.EncodeToString(digest[:]),
			Epoch:    epoch,
			Sequence: sequence,
		}
		line, err := json.Marshal(record)
		if err != nil {
			return fmt.Errorf("encode journal record: %w", err)
		}
		encoded = append(encoded, line...)
		encoded = append(encoded, '\n')
	}

	if int64(len(encoded)) > journal.maxBytes-journal.bytes {
		return fmt.Errorf("journal would exceed %d-byte bound", journal.maxBytes)
	}

	written, err := journal.writer.Write(encoded)
	journal.bytes += int64(written)
	if err != nil {
		return fmt.Errorf("write journal batch: %w", err)
	}
	if written != len(encoded) {
		return fmt.Errorf("write journal batch: %w", io.ErrShortWrite)
	}
	if err := journal.writer.Flush(); err != nil {
		return fmt.Errorf("flush journal batch: %w", err)
	}
	if err := journal.file.Sync(); err != nil {
		return fmt.Errorf("sync journal batch: %w", err)
	}
	return nil
}

// Close flushes and closes the journal.
func (journal *Journal) Close() error {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	if journal.closed {
		return nil
	}
	journal.closed = true
	if err := journal.writer.Flush(); err != nil {
		_ = journal.file.Close()
		return fmt.Errorf("flush journal: %w", err)
	}
	if err := journal.file.Close(); err != nil {
		return fmt.Errorf("close journal: %w", err)
	}
	return nil
}

// EventPayload is the immutable payload retained by the receiver.
type EventPayload struct {
	ID            string
	CanonicalJSON []byte
}
