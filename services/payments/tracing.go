package main

import (
	"context"
	"log"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

// setupTracing configures the OTel SDK to export spans to the ADOT
// Collector sidecar over OTLP/gRPC on localhost — every backend task
// runs its application alongside an ADOT sidecar per the brief's
// platform baseline, so the sidecar is always reachable at localhost
// from inside the same task.
//
// If OTEL_EXPORTER_OTLP_ENDPOINT is unset (e.g. running locally without
// a sidecar), tracing degrades to a no-op rather than failing startup —
// so this is always safe to call, in every environment.
func setupTracing(serviceName string) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		// No sidecar configured — return a no-op shutdown so callers
		// don't need to branch on whether tracing is actually active.
		return func(context.Context) error { return nil }, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(endpoint),
		otlptracegrpc.WithInsecure(), // sidecar traffic stays inside the task, TLS not needed
	)
	if err != nil {
		return nil, err
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
		),
	)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	log.Printf("tracing: exporting to %s as service %q", endpoint, serviceName)

	return tp.Shutdown, nil
}

// tracer is the package-level tracer every handler uses to start spans.
var tracer = otel.Tracer("tillflow/payments")

// spanAttrs extracts the current span's trace_id and span_id as strings,
// for embedding in log lines — this is what lets Grafana correlate a log
// line with its trace, per the contract's Observability requirement that
// JSON logs carry trace_id/span_id.
func spanAttrs(ctx context.Context) (traceID, spanID string) {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return "", ""
	}
	return sc.TraceID().String(), sc.SpanID().String()
}