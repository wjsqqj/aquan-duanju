package contract

import "testing"

func fieldsOf(t *testing.T, raw string) []Field {
	t.Helper()
	fields, err := Shape([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	return fields
}

func TestShapeStepsIntoEmbeddedObject(t *testing.T) {
	fields := fieldsOf(t, `{"data":{"video_model":"{\"video_list\":[{\"main_url\":\"u\"}]}"}}`)
	want := "data.video_model{}.video_list[].main_url"
	for _, f := range fields {
		if f.Path == want && f.Type == "string" {
			return
		}
	}
	t.Fatalf("shape = %+v, want path %s", fields, want)
}

func TestCompareToleratesOptionalShapes(t *testing.T) {
	// 夹具：标量、空数组、空对象；live：标量变 null（满足标量）、数组有元素、
	// 对象有子字段，且多出夹具没有的字段——都不算漂移。
	fixture := fieldsOf(t, `{"a":"x","b":[],"c":{}}`)
	live := fieldsOf(t, `{"a":null,"b":[{"k":1}],"c":{"k":1},"extra":true}`)
	if drifts := Compare(fixture, live); len(drifts) != 0 {
		t.Fatalf("drifts = %v", drifts)
	}
}

func TestCompareReportsMissingAndTypeChange(t *testing.T) {
	fixture := fieldsOf(t, `{"a":"x","b":{"c":1}}`)
	live := fieldsOf(t, `{"a":1}`)
	drifts := Compare(fixture, live)
	if len(drifts) != 2 {
		t.Fatalf("drifts = %v", drifts)
	}
	byPath := map[string]Drift{}
	for _, d := range drifts {
		byPath[d.Path] = d
	}
	if got := byPath["a"]; got.Want != "string" || len(got.Got) != 1 || got.Got[0] != "number" {
		t.Fatalf("a drift = %+v", got)
	}
	if got := byPath["b.c"]; got.Want != "number" || len(got.Got) != 0 {
		t.Fatalf("b.c drift = %+v", got)
	}
}
