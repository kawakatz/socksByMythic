package main

import (
	"bytes"
	"encoding/json"
	"net"
	"reflect"
	"strings"
	"testing"
	"testing/iotest"
)

func TestNegotiateNoAuth(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() { done <- negotiateNoAuth(server) }()

	if _, err := client.Write([]byte{5, 2, 2, 0}); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 2)
	if _, err := client.Read(reply); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(reply, []byte{5, 0}) {
		t.Fatalf("reply = %v", reply)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestReadSOCKSRequest(t *testing.T) {
	want := []byte{5, 1, 0, 3, 11, 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm', 1, 187}
	got, err := readSOCKSRequest(iotest.OneByteReader(bytes.NewReader(want)))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("request = %v, want %v", got, want)
	}
}

func TestProxyMessageJSON(t *testing.T) {
	const wire = `[{"server_id":7,"data":"aGk=","exit":false}]`
	var messages []proxyMessage
	if err := json.Unmarshal([]byte(wire), &messages); err != nil {
		t.Fatal(err)
	}
	want := []proxyMessage{{ServerID: 7, Data: []byte("hi")}}
	if !reflect.DeepEqual(messages, want) {
		t.Fatalf("messages = %#v, want %#v", messages, want)
	}
	encoded, err := json.Marshal(messages)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), `"port"`) {
		t.Fatalf("zero port was not omitted: %s", encoded)
	}
}
