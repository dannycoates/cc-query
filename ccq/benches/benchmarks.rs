//! Benchmarks for ccq performance tracking.

use std::path::Path;

use criterion::{black_box, criterion_group, criterion_main, Criterion};

use ccq::QuerySession;

// Path to fixtures relative to the benchmark working directory (ccq/)
const SIMPLE_FIXTURE: &str = "../test/fixtures";
const COMPLEX_FIXTURE: &str = "../test/fixtures/complex";

fn startup_simple(c: &mut Criterion) {
    let path = Path::new(SIMPLE_FIXTURE);
    c.bench_function("startup_simple", |b| {
        b.iter(|| {
            QuerySession::create(None, None, Some(black_box(path))).unwrap();
        });
    });
}

fn startup_complex(c: &mut Criterion) {
    let path = Path::new(COMPLEX_FIXTURE);
    c.bench_function("startup_complex", |b| {
        b.iter(|| {
            QuerySession::create(None, None, Some(black_box(path))).unwrap();
        });
    });
}

fn query_count(c: &mut Criterion) {
    let path = Path::new(SIMPLE_FIXTURE);
    let session = QuerySession::create(None, None, Some(path)).unwrap();

    c.bench_function("query_count", |b| {
        b.iter(|| {
            session
                .query(black_box("SELECT COUNT(*) FROM messages"))
                .unwrap();
        });
    });
}

fn query_group_by(c: &mut Criterion) {
    let path = Path::new(SIMPLE_FIXTURE);
    let session = QuerySession::create(None, None, Some(path)).unwrap();

    c.bench_function("query_group_by", |b| {
        b.iter(|| {
            session
                .query(black_box(
                    "SELECT type, count(*) FROM messages GROUP BY type",
                ))
                .unwrap();
        });
    });
}

fn query_json_extract(c: &mut Criterion) {
    let path = Path::new(SIMPLE_FIXTURE);
    let session = QuerySession::create(None, None, Some(path)).unwrap();

    c.bench_function("query_json_extract", |b| {
        b.iter(|| {
            session
                .query(black_box(
                    "SELECT message->>'role', message->>'model' FROM assistant_messages LIMIT 10",
                ))
                .unwrap();
        });
    });
}

criterion_group!(
    benches,
    startup_simple,
    startup_complex,
    query_count,
    query_group_by,
    query_json_extract
);
criterion_main!(benches);
