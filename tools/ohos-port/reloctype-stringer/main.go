// Command reloctype-stringer regenerates src/cmd/internal/objabi/reloctype_string.go
// for the HarmonyBridge OHOS Go port.
//
// Why this exists instead of just running `stringer -type=RelocType`:
//
//	The OHOS port adds one constant (R_ARM64_TLS_GD) in the middle of the
//	RelocType block, which shifts the numeric value of every constant after it.
//	The reference implementation (OpenHarmony SIG, release-branch.go1.24) ships
//	its own reloctype_string.go, but that file was generated from the go1.24
//	constant list and is therefore wrong for go1.26 (whose list gained
//	R_DWTXTADDR_* and others). Copying it would silently mis-map names to
//	values. This program re-derives the file from the actual go1.26 constant
//	list, so the result is correct by construction.
//
// It reproduces the exact layout of golang.org/x/tools/cmd/stringer's output:
// the `_()` index-assertion function, the concatenated `_RelocType_name`
// string, and the `_RelocType_index` offset table.
//
// Usage:
//
//	go run . -src <path to reloctype.go> -out <path to reloctype_string.go>
package main

import (
	"bytes"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strconv"
	"strings"
)

func main() {
	src := flag.String("src", "", "path to reloctype.go")
	out := flag.String("out", "", "path to write reloctype_string.go (- for stdout)")
	typename := flag.String("type", "RelocType", "name of the constant type to stringify")
	flag.Parse()

	if *src == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "usage: reloctype-stringer -src reloctype.go -out reloctype_string.go")
		os.Exit(2)
	}

	names, err := collect(*src, *typename)
	if err != nil {
		fmt.Fprintln(os.Stderr, "reloctype-stringer:", err)
		os.Exit(1)
	}
	if len(names) == 0 {
		fmt.Fprintf(os.Stderr, "reloctype-stringer: no constants of type %s found\n", *typename)
		os.Exit(1)
	}

	got := generate(*typename, names)

	if *out == "-" {
		os.Stdout.Write(got)
		return
	}
	prev, err := os.ReadFile(*out)
	if err != nil && !os.IsNotExist(err) {
		fmt.Fprintln(os.Stderr, "reloctype-stringer:", err)
		os.Exit(1)
	}
	if bytes.Equal(prev, got) {
		fmt.Printf("%s: unchanged (%d %s constants)\n", *out, len(names), *typename)
		return
	}
	if err := os.WriteFile(*out, got, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "reloctype-stringer:", err)
		os.Exit(1)
	}
	fmt.Printf("%s: written (%d %s constants)\n", *out, len(names), *typename)
}

// collect parses filename and returns the names of every constant belonging to
// the named type, in source order. That order defines the numeric values, which
// is exactly what stringer relies on.
func collect(filename, typename string) ([]string, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, nil, parser.SkipObjectResolution)
	if err != nil {
		return nil, err
	}

	// stringer emits only the run of consecutive-valued constants at the start
	// of the block. In reloctype.go the RelocType block ends with R_WEAK
	// (= -1<<15) and two bitwise-OR expressions whose values are not
	// consecutive, and stringer stops there. We reproduce that behaviour.
	var (
		names    []string
		lastExpr ast.Expr
		next     int64 = 1
	)
	for _, decl := range file.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.CONST {
			continue
		}
		if !groupIsTyped(gen, typename) {
			continue
		}
		for i, raw := range gen.Specs {
			vs, ok := raw.(*ast.ValueSpec)
			if !ok {
				continue
			}
			if vs.Type != nil && !isType(vs.Type, typename) {
				continue
			}
			if len(vs.Values) > 0 {
				lastExpr = vs.Values[0]
			}
			if lastExpr == nil {
				return names, nil
			}
			v, ok := constInt(lastExpr, int64(i))
			if !ok || v != next {
				return names, nil
			}
			for _, n := range vs.Names {
				if n.Name == "_" {
					continue
				}
				names = append(names, n.Name)
				next++
			}
		}
	}
	return names, nil
}

// constInt evaluates the small subset of Go constant expressions used by the
// RelocType block: integer literals, `iota`, and the binary operators
// + - | << >> with integer operands.
func constInt(expr ast.Expr, iota int64) (int64, bool) {
	switch e := expr.(type) {
	case *ast.BasicLit:
		if e.Kind != token.INT {
			return 0, false
		}
		v, err := strconv.ParseInt(e.Value, 0, 64)
		return v, err == nil
	case *ast.Ident:
		if e.Name == "iota" {
			return iota, true
		}
		return 0, false
	case *ast.ParenExpr:
		return constInt(e.X, iota)
	case *ast.BinaryExpr:
		x, ok := constInt(e.X, iota)
		if !ok {
			return 0, false
		}
		y, ok := constInt(e.Y, iota)
		if !ok {
			return 0, false
		}
		switch e.Op {
		case token.ADD:
			return x + y, true
		case token.SUB:
			return x - y, true
		case token.OR:
			return x | y, true
		case token.SHL:
			return x << uint(y), true
		case token.SHR:
			return x >> uint(y), true
		}
		return 0, false
	}
	return 0, false
}

func isType(expr ast.Expr, typename string) bool {
	ident, ok := expr.(*ast.Ident)
	return ok && ident.Name == typename
}

func groupIsTyped(gen *ast.GenDecl, typename string) bool {
	if len(gen.Specs) == 0 {
		return false
	}
	vs, ok := gen.Specs[0].(*ast.ValueSpec)
	if !ok || vs.Type == nil {
		return false
	}
	return isType(vs.Type, typename)
}

// generate builds the stringer-compatible output.
func generate(typename string, names []string) []byte {
	var b bytes.Buffer
	fmt.Fprintf(&b, "// Code generated by \"stringer -type=%s\"; DO NOT EDIT.\n\n", typename)
	b.WriteString("package objabi\n\n")
	b.WriteString("import \"strconv\"\n\n")
	b.WriteString("func _() {\n")
	b.WriteString("\t// An \"invalid array index\" compiler error signifies that the constant values have changed.\n")
	b.WriteString("\t// Re-run the stringer command to generate them again.\n")
	b.WriteString("\tvar x [1]struct{}\n")
	// Values in this block start at 1 (R_ADDR-1).
	for i, name := range names {
		fmt.Fprintf(&b, "\t_ = x[%s-%d]\n", name, i+1)
	}
	b.WriteString("}\n\n")

	fmt.Fprintf(&b, "const _%s_name = %q\n\n", typename, strings.Join(names, ""))

	// Byte offsets into the concatenated name string; element i spans
	// [index[i], index[i+1]) and the table ends with the total length.
	offsets := make([]int, 0, len(names)+1)
	total := 0
	for _, name := range names {
		offsets = append(offsets, total)
		total += len(name)
	}
	offsets = append(offsets, total)

	parts := make([]string, len(offsets))
	for i, v := range offsets {
		parts[i] = strconv.Itoa(v)
	}
	fmt.Fprintf(&b, "var _%s_index = [...]uint16{%s}\n\n", typename, strings.Join(parts, ", "))

	fmt.Fprintf(&b, "func (i %s) String() string {\n", typename)
	b.WriteString("\ti -= 1\n")
	fmt.Fprintf(&b, "\tif i < 0 || i >= %s(len(_%s_index)-1) {\n", typename, typename)
	fmt.Fprintf(&b, "\t\treturn \"%s(\" + strconv.FormatInt(int64(i+1), 10) + \")\"\n", typename)
	b.WriteString("\t}\n")
	fmt.Fprintf(&b, "\treturn _%s_name[_%s_index[i]:_%s_index[i+1]]\n", typename, typename, typename)
	b.WriteString("}\n")
	return b.Bytes()
}
