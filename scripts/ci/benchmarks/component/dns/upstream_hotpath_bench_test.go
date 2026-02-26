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
	// atomic.Pointer[T] internals: write pointer directly into field "v".
	vField := stateField.FieldByName("v")
	if !vField.IsValid() {
		b.Fatalf("atomic pointer backing field not found")
	}
	if vField.Type().Kind() != reflect.UnsafePointer {
		b.Fatalf("unexpected atomic backing field type: %v", vField.Type())
	}
	// Derive *upstreamState type from stateField methods.
	load := stateField.Addr().MethodByName("Load")
	if !load.IsValid() || load.Type().NumOut() != 1 {
		b.Fatalf("state.Load method unavailable")
	}
	upstreamStatePtrType := load.Type().Out(0)
	if upstreamStatePtrType.Kind() != reflect.Pointer {
		b.Fatalf("unexpected Load output type: %v", upstreamStatePtrType)
	}
	state := reflect.New(upstreamStatePtrType.Elem())
	stateUpstreamField := state.Elem().FieldByName("upstream")
	if !stateUpstreamField.IsValid() {
		b.Fatalf("upstreamState.upstream field missing")
	}
	setField(stateUpstreamField, reflect.ValueOf(up))
	setField(vField, reflect.ValueOf(unsafe.Pointer(state.Pointer())))
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
