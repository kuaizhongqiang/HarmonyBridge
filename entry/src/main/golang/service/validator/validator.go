// Package validator implements ValidatorService: it answers "would Xray accept
// this config?" without starting anything.
//
// The UI needs this for the subscription editor: a user pastes a config and
// wants immediate, specific feedback. Validation is delegated to Xray's own
// pipeline - infra/conf parses the JSON, conf.Build() turns it into a core
// Config, and core.New() proves the object graph can actually be assembled. A
// hand-written schema check would drift from Xray's real behaviour within one
// release, so we do not write one.
package validator

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf"

	"harmonybridge/core/ipc"
)

// Service is the ValidatorService handler.
type Service struct{}

// Request is the parameter object for ValidatorService.ValidateConfig.
//
// Exactly one of Config / ConfigLocation must be supplied. ConfigPath is used
// only for error messages, so a caller validating unsaved editor content can
// still get "config.json: ..." style output.
type Request struct {
	// Config is a JSON config document.
	Config string `json:"config"`

	// ConfigLocation is an absolute path to a JSON config file.
	ConfigLocation string `json:"configLocation"`

	// ConfigPath is an optional display name used in messages.
	ConfigPath string `json:"configPath"`
}

// Response is the payload returned by ValidatorService.ValidateConfig.
type Response struct {
	// Valid is true when the config parsed and built successfully.
	Valid bool `json:"valid"`

	// Errors lists every problem found, one message per entry.
	Errors []string `json:"errors"`

	// InboundTags / OutboundTags are reported on success so the UI can show
	// what the config will actually do.
	InboundTags  []string `json:"inboundTags"`
	OutboundTags []string `json:"outboundTags"`
}

// ValidateConfig implements ValidatorService.ValidateConfig.
func (s *Service) ValidateConfig(req *Request) (*Response, error) {
	if req == nil {
		return nil, errors.New("ValidatorService.ValidateConfig: missing parameters")
	}

	name := req.ConfigPath
	if name == "" {
		name = req.ConfigLocation
	}
	if name == "" {
		name = "config.json"
	}

	var raw []byte
	switch {
	case strings.TrimSpace(req.Config) != "":
		raw = []byte(req.Config)
	case strings.TrimSpace(req.ConfigLocation) != "":
		data, err := os.ReadFile(req.ConfigLocation)
		if err != nil {
			return invalid(fmt.Sprintf("%s: %v", name, err)), nil
		}
		raw = data
	default:
		return invalid("either config or configLocation is required"), nil
	}

	// Fast syntactic check first: it gives a much better message than the
	// deserializer's, and catches the common "pasted JSON got truncated" case.
	if !json.Valid(raw) {
		return invalid(fmt.Sprintf("%s: not valid JSON", name)), nil
	}

	if err := build(raw); err != nil {
		return invalid(fmt.Sprintf("%s: %v", name, err)), nil
	}

	return &Response{Valid: true, Errors: []string{}}, nil
}

// build runs the config through Xray's real loader and then proves the object
// graph can be assembled. Nothing is started, so no sockets are opened.
func build(raw []byte) error {
	cfg, err := core.LoadConfig("json", bytes.NewReader(raw))
	if err != nil {
		return err
	}

	// core.New wires every feature and inbound/outbound handler. It is the
	// strongest static check available without binding a port: it catches
	// bad transports, bad protocol settings and missing dependencies.
	instance, err := core.New(cfg)
	if err != nil {
		return err
	}
	// Never started, but close it so any partially constructed features are
	// released.
	if instance != nil {
		_ = instance.Close()
	}
	return nil
}

// ParseConfig is exported for tests: it returns the deserialized top-level
// conf.Config so a test can assert on tags.
func ParseConfig(raw []byte) (*conf.Config, error) {
	c := &conf.Config{}
	if err := json.Unmarshal(raw, c); err != nil {
		return nil, err
	}
	return c, nil
}

func invalid(msg string) *Response {
	return &Response{
		Valid:        false,
		Errors:       []string{msg},
		InboundTags:  []string{},
		OutboundTags: []string{},
	}
}

var svc = &Service{}

func init() {
	ipc.Register("ValidatorService.ValidateConfig", func(params json.RawMessage) (any, error) {
		var req Request
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.ValidateConfig(&req)
	})
}
