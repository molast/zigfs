package middleware

import "testing"

func TestRequestIDValidationMatchesZigFS(t *testing.T) {
	t.Parallel()

	valid := []string{"client-request_01", "trace.example:42"}
	for _, value := range valid {
		if !isValidRequestID(value) {
			t.Fatalf("expected %q to be valid", value)
		}
	}

	invalid := []string{"", "contains whitespace", "contains\r\nheader", "request/id"}
	for _, value := range invalid {
		if isValidRequestID(value) {
			t.Fatalf("expected %q to be invalid", value)
		}
	}

	tooLong := make([]byte, 129)
	for index := range tooLong {
		tooLong[index] = 'x'
	}
	if isValidRequestID(string(tooLong)) {
		t.Fatal("expected a request ID longer than 128 bytes to be invalid")
	}
}
