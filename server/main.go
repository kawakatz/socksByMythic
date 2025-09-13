// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2025, kawakatz
//
// Uses Mythic components as dependencies; see LICENSE for third-party notices.

package main

import (
	"compress/flate"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/its-a-feature/Mythic/rabbitmq"

	_ "net/http/pprof"
)

var upgrader = websocket.Upgrader{
	CheckOrigin:       func(r *http.Request) bool { return true },
	EnableCompression: true,
}

func wsHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("upgrade error:", err)
		return
	}
	defer conn.Close()

	fmt.Println("Client connected")

	// compress?
	conn.EnableWriteCompression(true)
	_ = conn.SetCompressionLevel(flate.BestSpeed)

	incoming := make(chan []byte)
	done := make(chan struct{})
	go func() {
		for {
			_, message, err := conn.ReadMessage()
			if err != nil {
				fmt.Println("Client disconnected")
				close(done)
				return
			}
			incoming <- message
		}
	}()

	const (
		coalesce = 3 * time.Millisecond // micro-batch window
		maxItems = 128                  // cap to avoid huge frames
		writeTO  = 10 * time.Second
	)

	for {
		select {
		case <-done:
			fmt.Println("done")
			return
		case first := <-newPort.MessagesToAgent:
			// micro-batch: gather additional messages within a short window
			batch := make([]rabbitmq.ProxyToAgentMessage, 0, 32)
			batch = append(batch, first)
			deadline := time.Now().Add(coalesce)
			for len(batch) < maxItems && time.Now().Before(deadline) {
				select {
				case m := <-newPort.MessagesToAgent:
					batch = append(batch, m)
				default:
					time.Sleep(200 * time.Microsecond)
				}
			}

			// encode once as JSON array
			payload, err := json.Marshal(batch) // no trailing newline
			if err != nil {
				log.Println("marshal batch:", err)
				return
			}

			// single text frame write (1 writer rule)
			_ = conn.SetWriteDeadline(time.Now().Add(writeTO))
			wr, err := conn.NextWriter(websocket.TextMessage)
			if err != nil {
				log.Println("NextWriter:", err)
				return
			}
			if _, err = wr.Write(payload); err != nil {
				_ = wr.Close()
				log.Println("write payload:", err)
				return
			}
			if err = wr.Close(); err != nil {
				log.Println("close writer:", err)
				return
			}

			fmt.Printf("Sent(batch): %d item(s), %d bytes\n", len(batch), len(payload))
		case b := <-incoming:
			fmt.Println("<-incoming")
			var batch []rabbitmq.ProxyFromAgentMessage
			if err := json.Unmarshal(b, &batch); err != nil {
				// malformed JSON or not an array
				return
			}
			fmt.Printf("Received: %d\n", len(batch))
			//fmt.Printf("Received: %s\n", b)

			for _, msg := range batch {
				select {
				case newPort.MessagesFromAgent <- msg:
				}
			}
		}
	}
}

var newPort rabbitmq.CallbackPortUsage

func main() {
	newPort = rabbitmq.CallbackPortUsage{
		CallbackPortID:               1,
		CallbackID:                   2,
		TaskID:                       3,
		LocalPort:                    7000, // socks5://0.0.0.0:7000
		RemotePort:                   4,
		RemoteIP:                     "",
		OperationID:                  5,
		PortType:                     "socks",
		Username:                     "",
		Password:                     "",
		BytesSentToAgentChan:         make(chan rabbitmq.BytesSentToAgentMessage, 2000),
		BytesReceivedFromAgentChan:   make(chan rabbitmq.BytesReceivedFromAgentMessage, 2000),
		MessagesToAgent:              make(chan rabbitmq.ProxyToAgentMessage, 1000),
		NewConnectionChannel:         make(chan *rabbitmq.AcceptedConnection, 1000),
		RemoveConnectionsChannel:     make(chan *rabbitmq.AcceptedConnection, 1000),
		MessagesFromAgent:            make(chan rabbitmq.ProxyFromAgentMessage, 1000),
		InteractiveMessagesToAgent:   make(chan rabbitmq.AgentMessagePostResponseInteractive, 1000),
		InteractiveMessagesFromAgent: make(chan rabbitmq.AgentMessagePostResponseInteractive, 1000),
		StopAllConnections:           make(chan bool),
	}
	acceptedConnections := make([]*rabbitmq.AcceptedConnection, 0)
	newPort.AcceptedConnections = &acceptedConnections
	fmt.Print("starting socks...\n")
	_ = newPort.Start()
	fmt.Print("socks started\n")

	http.HandleFunc("/ws", wsHandler)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})
	go func() {
		if err := http.ListenAndServe(":80", nil); err != nil {
			log.Printf("HTTP server error: %v\n", err)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	fmt.Println("Press Ctrl+C to exit")
	<-ctx.Done()
	fmt.Println("bye")
}
