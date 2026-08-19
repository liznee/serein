package api

import (
	"strings"
	"testing"
)

func TestAddArtifactHashHeader(t *testing.T) {
	cmd := "python -c \"import subprocess,urllib.request; req=urllib.request.Request('url',data=open('/tmp/serein-server','rb').read(),method='POST'); req.add_header('Content-Type','application/octet-stream');\""
	got := addArtifactHashHeader(cmd)

	for _, want := range []string{
		"import subprocess,urllib.request,hashlib;",
		"data=(data:=open('/tmp/serein-server','rb').read())",
		"X-Binary-SHA256",
		"hashlib.sha256(data).hexdigest()",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("generated command missing %q: %s", want, got)
		}
	}
	if strings.Contains(got, "data=open('/tmp/serein-server','rb').read(),method='POST'") {
		t.Fatal("generated command still uses an unhashed upload body")
	}
}
