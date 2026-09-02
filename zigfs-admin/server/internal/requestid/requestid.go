package requestid

import "context"

type contextKey struct{}

func WithContext(ctx context.Context, requestID string) context.Context {
	return context.WithValue(ctx, contextKey{}, requestID)
}

func FromContext(ctx context.Context) string {
	requestID, _ := ctx.Value(contextKey{}).(string)
	return requestID
}
