package util

import (
	"encoding/json"
	"testing"

	mdx "github.com/go-gost/x/metadata"
)

func TestGetIntSupportsJSONNumbers(t *testing.T) {
	tests := []struct {
		name  string
		value any
		want  int
	}{
		{name: "int", value: 2, want: 2},
		{name: "float32", value: float32(2), want: 2},
		{name: "float64 from encoding json", value: float64(2), want: 2},
		{name: "json number", value: json.Number("2"), want: 2},
		{name: "string", value: "2", want: 2},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			md := mdx.NewMetadata(map[string]any{"proxyProtocol": tt.value})
			if got := GetInt(md, "proxyProtocol"); got != tt.want {
				t.Fatalf("GetInt() = %d, want %d", got, tt.want)
			}
		})
	}
}
