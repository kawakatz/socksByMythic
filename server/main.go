// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2018, Cody Thomas
// Copyright (c) 2025, kawakatz

package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

const (
	socks5Version = 5
	socks5NoAuth  = 0
	maxFrameSize  = 8 << 20
	maxBatchSize  = 128
	batchWindow   = 3 * time.Millisecond
)

type proxyMessage struct {
	ServerID uint32 `json:"server_id"`
	Data     []byte `json:"data"`
	Exit     bool   `json:"exit"`
	Port     int    `json:"port,omitempty"`
}

type agentSession struct {
	outbound chan proxyMessage
	done     chan struct{}
}

type proxyConnection struct {
	bridge      *bridge
	session     *agentSession
	conn        net.Conn
	id          uint32
	inbound     chan proxyMessage
	done        chan struct{}
	once        sync.Once
	agentClosed atomic.Bool
}

type bridge struct {
	listener net.Listener
	port     int
	nextID   atomic.Uint32

	mu          sync.Mutex
	agent       *agentSession
	connections map[uint32]*proxyConnection
}

var upgrader = websocket.Upgrader{EnableCompression: true}

func newBridge(address string) (*bridge, error) {
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return nil, err
	}
	return &bridge{
		listener:    listener,
		port:        listener.Addr().(*net.TCPAddr).Port,
		connections: make(map[uint32]*proxyConnection),
	}, nil
}

func (b *bridge) serve(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		_ = b.listener.Close()
	}()

	for {
		conn, err := b.listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		session := b.currentAgent()
		if session == nil {
			_ = conn.Close()
			continue
		}
		go b.handleConnection(session, conn)
	}
}

func (b *bridge) currentAgent() *agentSession {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.agent
}

func (b *bridge) connectAgent() (*agentSession, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.agent != nil {
		return nil, false
	}
	session := &agentSession{
		outbound: make(chan proxyMessage, 256),
		done:     make(chan struct{}),
	}
	b.agent = session
	return session, true
}

func (b *bridge) disconnectAgent(session *agentSession) {
	if session == nil {
		return
	}
	b.mu.Lock()
	if b.agent != session {
		b.mu.Unlock()
		return
	}
	b.agent = nil
	close(session.done)
	connections := make([]*proxyConnection, 0, len(b.connections))
	for _, connection := range b.connections {
		if connection.session == session {
			connection.agentClosed.Store(true)
			connections = append(connections, connection)
		}
	}
	b.mu.Unlock()

	for _, connection := range connections {
		connection.close()
	}
}

func (b *bridge) handleConnection(session *agentSession, conn net.Conn) {
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := negotiateNoAuth(conn); err != nil {
		_ = conn.Close()
		return
	}
	request, err := readSOCKSRequest(conn)
	if err != nil {
		_ = conn.Close()
		return
	}
	_ = conn.SetDeadline(time.Time{})

	connection := &proxyConnection{
		bridge:  b,
		session: session,
		conn:    conn,
		inbound: make(chan proxyMessage, 64),
		done:    make(chan struct{}),
	}

	b.mu.Lock()
	if b.agent != session {
		b.mu.Unlock()
		_ = conn.Close()
		return
	}
	for connection.id == 0 || b.connections[connection.id] != nil {
		connection.id = b.nextID.Add(1)
	}
	b.connections[connection.id] = connection
	b.mu.Unlock()

	go connection.writeToLocal()
	if !b.send(session, proxyMessage{ServerID: connection.id, Data: request, Port: b.port}) {
		connection.close()
		return
	}

	buffer := make([]byte, 32*1024)
	for {
		n, err := conn.Read(buffer)
		if n > 0 {
			data := append([]byte(nil), buffer[:n]...)
			if !b.send(session, proxyMessage{ServerID: connection.id, Data: data, Port: b.port}) {
				connection.close()
				return
			}
		}
		if err != nil {
			connection.close()
			return
		}
	}
}

func (b *bridge) send(session *agentSession, message proxyMessage) bool {
	select {
	case session.outbound <- message:
		return true
	case <-session.done:
		return false
	}
}

func (b *bridge) deliver(session *agentSession, message proxyMessage) {
	b.mu.Lock()
	connection := b.connections[message.ServerID]
	if connection != nil && connection.session != session {
		connection = nil
	}
	b.mu.Unlock()

	if connection == nil {
		if !message.Exit {
			b.send(session, proxyMessage{ServerID: message.ServerID, Exit: true, Port: b.port})
		}
		return
	}
	if message.Exit {
		connection.agentClosed.Store(true)
	}
	select {
	case connection.inbound <- message:
	case <-connection.done:
	case <-session.done:
	}
}

func (c *proxyConnection) writeToLocal() {
	for {
		select {
		case message := <-c.inbound:
			if len(message.Data) > 0 {
				_ = c.conn.SetWriteDeadline(time.Now().Add(30 * time.Second))
				if err := writeAll(c.conn, message.Data); err != nil {
					c.close()
					return
				}
				_ = c.conn.SetWriteDeadline(time.Time{})
			}
			if message.Exit {
				c.close()
				return
			}
		case <-c.done:
			return
		case <-c.session.done:
			return
		}
	}
}

func (c *proxyConnection) close() {
	c.once.Do(func() {
		close(c.done)
		_ = c.conn.Close()

		c.bridge.mu.Lock()
		if c.bridge.connections[c.id] == c {
			delete(c.bridge.connections, c.id)
		}
		c.bridge.mu.Unlock()

		if !c.agentClosed.Load() {
			c.bridge.send(c.session, proxyMessage{ServerID: c.id, Exit: true, Port: c.bridge.port})
		}
	})
}

func (b *bridge) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	session, ok := b.connectAgent()
	if !ok {
		http.Error(w, "an agent is already connected", http.StatusConflict)
		return
	}
	defer b.disconnectAgent(session)

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	conn.SetReadLimit(maxFrameSize)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go func() {
		_ = writeBatches(ctx, conn, session)
		_ = conn.Close()
	}()

	for {
		messageType, payload, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if messageType != websocket.TextMessage && messageType != websocket.BinaryMessage {
			continue
		}
		var batch []proxyMessage
		if err := json.Unmarshal(payload, &batch); err != nil {
			_ = conn.WriteControl(
				websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseUnsupportedData, "invalid proxy message"),
				time.Now().Add(time.Second),
			)
			return
		}
		for _, message := range batch {
			b.deliver(session, message)
		}
	}
}

func writeBatches(ctx context.Context, conn *websocket.Conn, session *agentSession) error {
	for {
		var first proxyMessage
		select {
		case first = <-session.outbound:
		case <-session.done:
			return nil
		case <-ctx.Done():
			return nil
		}

		batch := []proxyMessage{first}
		timer := time.NewTimer(batchWindow)
	collect:
		for len(batch) < maxBatchSize {
			select {
			case message := <-session.outbound:
				batch = append(batch, message)
			case <-timer.C:
				break collect
			case <-session.done:
				timer.Stop()
				return nil
			case <-ctx.Done():
				timer.Stop()
				return nil
			}
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		_ = conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if err := conn.WriteJSON(batch); err != nil {
			return err
		}
	}
}

func negotiateNoAuth(conn net.Conn) error {
	var header [2]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return err
	}
	if header[0] != socks5Version || header[1] == 0 {
		return errors.New("invalid SOCKS5 greeting")
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(conn, methods); err != nil {
		return err
	}
	for _, method := range methods {
		if method == socks5NoAuth {
			return writeAll(conn, []byte{socks5Version, socks5NoAuth})
		}
	}
	_ = writeAll(conn, []byte{socks5Version, 0xff})
	return errors.New("client does not support unauthenticated SOCKS5")
}

func readSOCKSRequest(reader io.Reader) ([]byte, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, err
	}
	if header[0] != socks5Version || header[2] != 0 {
		return nil, errors.New("invalid SOCKS5 request")
	}

	request := append([]byte(nil), header...)
	addressSize := 0
	switch header[3] {
	case 1:
		addressSize = 4
	case 3:
		var length [1]byte
		if _, err := io.ReadFull(reader, length[:]); err != nil {
			return nil, err
		}
		request = append(request, length[0])
		addressSize = int(length[0])
	case 4:
		addressSize = 16
	default:
		return nil, errors.New("unsupported SOCKS5 address type")
	}

	tail := make([]byte, addressSize+2)
	if _, err := io.ReadFull(reader, tail); err != nil {
		return nil, err
	}
	return append(request, tail...), nil
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := writer.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	return nil
}

func run() error {
	httpAddress := flag.String("http", ":80", "HTTP/WebSocket listen address")
	socksAddress := flag.String("socks", ":7000", "SOCKS5 listen address")
	flag.Parse()

	proxy, err := newBridge(*socksAddress)
	if err != nil {
		return fmt.Errorf("listen for SOCKS5: %w", err)
	}
	httpListener, err := net.Listen("tcp", *httpAddress)
	if err != nil {
		_ = proxy.listener.Close()
		return fmt.Errorf("listen for HTTP: %w", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /ws", proxy.handleWebSocket)
	httpServer := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	signalContext, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithCancel(signalContext)
	defer cancel()

	errorsFromServer := make(chan error, 2)
	go func() { errorsFromServer <- proxy.serve(ctx) }()
	go func() {
		err := httpServer.Serve(httpListener)
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		errorsFromServer <- err
	}()

	log.Printf("SOCKS5 listening on %s", proxy.listener.Addr())
	log.Printf("WebSocket listening on http://%s/ws", httpListener.Addr())

	var runErr error
	select {
	case <-ctx.Done():
	case runErr = <-errorsFromServer:
	}
	cancel()

	proxy.disconnectAgent(proxy.currentAgent())
	_ = proxy.listener.Close()
	shutdownContext, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := httpServer.Shutdown(shutdownContext); err != nil && runErr == nil {
		runErr = err
	}
	return runErr
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
