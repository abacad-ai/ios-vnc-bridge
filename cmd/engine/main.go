// Command engine is the RFB half of iOS VNC Bridge.
//
// It is not a user-facing CLI: the macOS app launches it with a device bridge
// (bridge/iosbridge.py) and shows its log. This process only turns the bridge's
// JPEG frames and JSON touch commands into RFB, so abacad, macOS Screen
// Sharing, noVNC or any other VNC client can drive a paired iPhone or iPad.
//
// Two processes, on purpose: the Python bridge owns the device session (video
// stream, HID, keep-awake) because iOS only delivers HID reports to the process
// holding the stream, and this side owns the protocol work that is commodity
// and stable (RFB framing, encodings, scaling, auth).
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"

	"github.com/abacad-ai/ios-vnc-bridge/internal/helper"
	"github.com/abacad-ai/ios-vnc-bridge/internal/rfbserver"
)

func main() {
	log.SetFlags(log.Ltime)

	fs := flag.NewFlagSet("engine", flag.ContinueOnError)
	listen := fs.String("listen", "127.0.0.1:5970", "RFB listen address")
	password := fs.String("password", "", "require this VNC password (first 8 characters)")
	bridge := fs.String("helper", "", "path to the device bridge (bridge/iosbridge.py)")
	python := fs.String("helper-python", "", "interpreter for the device bridge")
	udid := fs.String("udid", "", "device UDID (empty: the first paired one)")
	connection := fs.String("connection", "usb", "reach the device over \"usb\" or \"wifi\"")
	name := fs.String("name", "iOS VNC Bridge", "desktop name shown to viewers")
	scale := fs.Float64("scale", 1.0, "output scale, 0 < scale <= 1")
	quality := fs.Int("quality", 70, "Tight/JPEG quality, 1-100")
	if err := fs.Parse(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	if *bridge == "" || *python == "" {
		fail(fmt.Errorf("the app must pass -helper and -helper-python"))
	}

	sup := helper.NewSupervisor(helper.Config{
		Python:     *python,
		Script:     *bridge,
		UDID:       *udid,
		Connection: *connection,
		Logf:       log.Printf,
	})
	// The app owns our stdin: the first line is the VNC password (so it never
	// shows up in `ps`), and the pipe staying open is a lifeline. If the app
	// dies (crash, force quit), the pipe closes and we stop too, instead of
	// serving the device as an orphan nobody can reach.
	stdin := bufio.NewReader(os.Stdin)
	if *password == "" {
		if line, err := stdin.ReadString('\n'); err == nil {
			*password = strings.TrimSpace(line)
		}
	}
	go func() {
		_, _ = io.Copy(io.Discard, stdin)
		log.Printf("engine: app went away; stopping")
		_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
	}()

	if err := sup.Start(context.Background()); err != nil {
		fail(err)
	}
	defer sup.Close()

	nativeW, nativeH := sup.Size()
	outW, outH := rfbserver.OutputSize(nativeW, nativeH, *scale)
	sup.SetOutputSize(outW, outH)
	log.Printf("engine: ready %dx%d (device %dx%d)", outW, outH, nativeW, nativeH)

	srv := rfbserver.New(sup, sup, rfbserver.Options{
		Name:     *name,
		Password: *password,
		Scale:    *scale,
		Quality:  *quality,
		Logf:     log.Printf,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go sup.Run(ctx)

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		fail(err)
	}
	defer ln.Close()
	log.Printf("listening on %s (RFB %dx%d%s)", ln.Addr(), outW, outH, authNote(*password))

	var wg sync.WaitGroup
	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			break
		}
		// A viewer that connects while the device session is down gets a closed
		// socket, not a stale frame pretending to be live.
		if !sup.Ready() {
			log.Printf("viewer %s refused: device session is not running", conn.RemoteAddr())
			_ = conn.Close()
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			log.Printf("viewer %s connected", conn.RemoteAddr())
			if err := srv.ServeConn(conn); err != nil {
				log.Printf("viewer %s: %v", conn.RemoteAddr(), err)
			}
			log.Printf("viewer %s disconnected", conn.RemoteAddr())
		}()
	}
	wg.Wait()
	log.Printf("engine: stopped")
}

func authNote(password string) string {
	if password == "" {
		return ", no password"
	}
	return ", password required"
}

func fail(err error) {
	log.Printf("engine: %v", err)
	os.Exit(1)
}
