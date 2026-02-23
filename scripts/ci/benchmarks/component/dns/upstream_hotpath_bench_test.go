package dns

import (
	"reflect"
	"testing"
	"unsafe"
)

var benchUpstreamSink *Upstream

func setField(field reflect.Value, value reflect.Value) {
	reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().Set(value)
}

func setBoolField(field reflect.Value, value bool) {
	reflect.NewAt(field.Type(), unsafe.Pointer(field.UnsafeAddr())).Elem().SetBool(value)
}

func benchmarkInitializedResolver(b *testing.B) *UpstreamResolver {
	r := &UpstreamResolver{}
	up := &Upstream{}
	rv := reflect.ValueOf(r).Elem()

	// Legacy layout (mutex + init flag).
	if initField := rv.FieldByName("init"); initField.IsValid() {
		upField := rv.FieldByName("upstream")
		if !upField.IsValid() {
			b.Fatalf("legacy upstream field missing")
		}
		setField(upField, reflect.ValueOf(up))
		setBoolField(initField, true)
		return r
	}

	// New layout (atomic state pointer).
	stateField := rv.FieldByName("state")
	if !stateField.IsValid() {
		b.Fatalf("unsupported UpstreamResolver layout")
	}
	store := stateField.Addr().MethodByName("Store")
	if !store.IsValid() || store.Type().NumIn() != 1 {
		b.Fatalf("state.Store method unavailable")
	}
	statePtrType := store.Type().In(0) // *upstreamState
	state := reflect.New(statePtrType.Elem())
	stateUpstreamField := state.Elem().FieldByName("upstream")
	if !stateUpstreamField.IsValid() {
		b.Fatalf("upstreamState.upstream field missing")
	}
	setField(stateUpstreamField, reflect.ValueOf(up))
	store.Call([]reflect.Value{state})
	return r
}

func BenchmarkUpstreamResolver_GetUpstream_Serial(b *testing.B) {
	r := benchmarkInitializedResolver(b)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		u, err := r.GetUpstream()
		if err != nil {
			b.Fatalf("GetUpstream failed: %v", err)
		}
		benchUpstreamSink = u
	}
}

func BenchmarkUpstreamResolver_GetUpstream_Parallel(b *testing.B) {
	r := benchmarkInitializedResolver(b)
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			u, err := r.GetUpstream()
			if err != nil {
				b.Fatalf("GetUpstream failed: %v", err)
			}
			benchUpstreamSink = u
		}
	})
}
