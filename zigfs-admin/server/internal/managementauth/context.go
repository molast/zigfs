package managementauth

import "context"

type tokenKey struct{}

func WithToken(ctx context.Context, token string) context.Context {
	return context.WithValue(ctx, tokenKey{}, token)
}

func Token(ctx context.Context) string {
	token, _ := ctx.Value(tokenKey{}).(string)
	return token
}
