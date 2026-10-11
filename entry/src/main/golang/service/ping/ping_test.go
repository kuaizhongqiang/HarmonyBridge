// Package ping_test tests PingService through its exported API only
// (`package ping_test`, matching service/config/config_test.go).
//
// The Tcping success path uses a real loopback listener instead of a mock, so
// the test covers the actual net.Dialer code that runs on the device.
package ping_test

import (
	"encoding/json"
	"net"
	"strconv"
	"strings"
	"testing"

	"harmonybridge/core/service/ping"
)

func TestSpeedTestDoesNotFakeAMeasurement(t *testing.T) {
	resp, err := (&ping.Service{}).SpeedTest(&ping.SpeedTestRequest{})
	if err != nil {
		t.Fatalf("SpeedTest returned an error: %v", err)
	}
	if resp.SpeedBps != 0 {
		t.Errorf("speedBps = %d, want 0: no measurement was taken (contract section 4.1)", resp.SpeedBps)
	}
	if len(resp.Notes) == 0 {
		t.Fatal("SpeedTest must explain why there is no number, otherwise 0 reads as a real result")
	}
	if !notesContain(resp.Notes, "未实现") {
		t.Errorf("notes do not say the measurement is unimplemented: %v", resp.Notes)
	}
}

func TestSpeedTestJSONFieldNames(t *testing.T) {
	blob, err := json.Marshal(&ping.SpeedTestResponse{})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	text := string(blob)
	for _, want := range []string{`"speedBps"`, `"notes"`} {
		if !strings.Contains(text, want) {
			t.Errorf("marshalled SpeedTest lacks %s: %s", want, text)
		}
	}
}

func TestTcpingJSONFieldNames(t *testing.T) {
	blob, err := json.Marshal(&ping.Response{LatencyMs: 12, Reachable: true})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	text := string(blob)
	if !strings.Contains(text, `"latencyMs"`) {
		t.Errorf("marshalled Tcping response lacks the contract field latencyMs: %s", text)
	}
	if strings.Contains(text, `"delayMs"`) {
		t.Errorf("the legacy delayMs field came back: %s", text)
	}
	if !strings.Contains(text, `"reachable"`) {
		t.Errorf("marshalled Tcping response lacks reachable: %s", text)
	}
}

func TestTcpingRejectsBadParameters(t *testing.T) {
	cases := []struct {
		name string
		req  *ping.Request
	}{
		{"nil request", nil},
		{"empty host", &ping.Request{Host: "", Port: 80}},
		{"zero port", &ping.Request{Host: "example.com", Port: 0}},
		{"negative port", &ping.Request{Host: "example.com", Port: -1}},
		{"port too large", &ping.Request{Host: "example.com", Port: 65536}},
	}

	for _, tc := range cases {
		if _, err := (&ping.Service{}).Tcping(tc.req); err == nil {
			t.Errorf("%s: expected an error, got none", tc.name)
		}
	}
}

// TestTcpingAgainstALiveListener is the success path: a real TCP listener on
// 127.0.0.1, so no DNS and no network access are involved and the test is
// repeatable on any machine.
func TestTcpingAgainstALiveListener(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("cannot open a loopback listener: %v", err)
	}
	// Draining accepted connections keeps the handshake completing even if the
	// dialer is slow, and closing the listener unblocks Accept.
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_ = conn.Close()
		}
	}()
	defer func() { _ = listener.Close() }()

	port := listener.Addr().(*net.TCPAddr).Port
	resp, err := (&ping.Service{}).Tcping(&ping.Request{
		Host:      "127.0.0.1",
		Port:      port,
		TimeoutMs: 2000,
	})
	if err != nil {
		t.Fatalf("Tcping to a live listener returned an error: %v", err)
	}
	if !resp.Reachable {
		t.Fatalf("loopback listener was reported unreachable: %+v", resp)
	}
	if resp.LatencyMs < 0 {
		t.Errorf("latencyMs = %d, want >= 0 on success", resp.LatencyMs)
	}
	if resp.Error != "" {
		t.Errorf("successful probe carried an error: %q", resp.Error)
	}
	if resp.Address != net.JoinHostPort("127.0.0.1", strconv.Itoa(port)) {
		t.Errorf("address = %q, want the dialled 127.0.0.1:%d", resp.Address, port)
	}
	if resp.IP != "127.0.0.1" {
		t.Errorf("ip = %q, want 127.0.0.1", resp.IP)
	}
}

// TestTcpingReportsAnUnreachablePort covers the failure path through the same
// real socket code: an ephemeral port that was just released is almost always
// closed, but the test tolerates the rare case where the OS hands it to
// somebody else.
func TestTcpingReportsAnUnreachablePort(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("cannot open a loopback listener: %v", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()

	resp, err := (&ping.Service{}).Tcping(&ping.Request{
		Host:      "127.0.0.1",
		Port:      port,
		TimeoutMs: 500,
	})
	if err != nil {
		t.Fatalf("Tcping reported a transport failure as an error: %v", err)
	}
	if resp.Reachable {
		t.Skipf("port %d was reused by another process; skipping the negative case", port)
	}
	if resp.LatencyMs != -1 {
		t.Errorf("latencyMs = %d on failure, want -1", resp.LatencyMs)
	}
	if resp.Error == "" {
		t.Error("an unreachable port must carry an error message")
	}
}

func notesContain(notes []string, want string) bool {
	for _, note := range notes {
		if strings.Contains(note, want) {
			return true
		}
	}
	return false
}
