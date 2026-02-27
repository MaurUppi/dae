package dns

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"runtime"
	"testing"
)

// Guardrail for benchmark overlay file used by CI:
// RunParallel body must not write package-level shared sink.
func TestUpstreamHotpathOverlay_NoSharedSinkWriteInParallelLoop(t *testing.T) {
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	overlayPath := filepath.Clean(filepath.Join(
		filepath.Dir(thisFile),
		"..", "..",
		"scripts", "ci", "benchmarks", "component", "dns", "upstream_hotpath_bench_test.go",
	))

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, overlayPath, nil, 0)
	if err != nil {
		t.Fatalf("parse overlay benchmark file: %v", err)
	}

	var target *ast.FuncDecl
	for _, d := range file.Decls {
		fn, ok := d.(*ast.FuncDecl)
		if !ok || fn.Name == nil {
			continue
		}
		if fn.Name.Name == "BenchmarkUpstreamResolver_GetUpstream_Parallel" {
			target = fn
			break
		}
	}
	if target == nil {
		t.Fatalf("BenchmarkUpstreamResolver_GetUpstream_Parallel not found")
	}

	foundRunParallel := false
	foundSharedSinkWriteInLoop := false

	ast.Inspect(target.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil || sel.Sel.Name != "RunParallel" {
			return true
		}
		if len(call.Args) != 1 {
			return true
		}
		fn, ok := call.Args[0].(*ast.FuncLit)
		if !ok || fn.Body == nil {
			return true
		}
		foundRunParallel = true

		ast.Inspect(fn.Body, func(m ast.Node) bool {
			loop, ok := m.(*ast.ForStmt)
			if !ok || loop.Body == nil {
				return true
			}
			ast.Inspect(loop.Body, func(x ast.Node) bool {
				assign, ok := x.(*ast.AssignStmt)
				if !ok {
					return true
				}
				for _, lhs := range assign.Lhs {
					id, ok := lhs.(*ast.Ident)
					if ok && id.Name == "benchUpstreamSink" {
						foundSharedSinkWriteInLoop = true
						return false
					}
				}
				return true
			})
			return !foundSharedSinkWriteInLoop
		})
		return !foundSharedSinkWriteInLoop
	})

	if !foundRunParallel {
		t.Fatalf("RunParallel call not found in benchmark")
	}
	if foundSharedSinkWriteInLoop {
		t.Fatalf("benchUpstreamSink must not be written inside RunParallel loop body")
	}
}
