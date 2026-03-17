# Kyverno CLI tests (semantic validation)

This directory is used by the validator for **semantic validation**; it runs **by default** when you run `validate.py` with `--output` (unless you pass **--skip-kyverno-test**). It runs **locally**—you do **not** need a Kubernetes cluster or Kind.

## Prerequisite

- **Kyverno CLI** on your PATH. Install from [Kyverno CLI docs](https://kyverno.io/docs/kyverno-cli/).

## What it does

- **`kyverno-test.yaml`** is a Test manifest (`cli.kyverno.io/v1alpha1`) that points at `../output/converted.yaml` and **resources.yaml**.
- **resources.yaml** contains sample Pods: one that should **pass** (has CPU and memory limits) and one that should **fail** (missing limits).
- When you run `validate.py` with `--output`, the script runs `kyverno test kyverno-tests/` by default (if the Kyverno CLI is on PATH). You can also run `kyverno test kyverno-tests/` manually. The CLI runs the converted policy against these resources and checks that the results match the expected pass/fail.

## Policy name

The test expects the converted policy to have **`metadata.name: require-resource-limits`** (same as the sample input). If your converter uses a different name, edit **kyverno-test.yaml** and change the `policy` field in each entry under `results` to match your policy’s `metadata.name`.

## Running

From the repo root:

```bash
kyverno test kyverno-tests/
```

Or as part of validation (runs by default; use **--skip-kyverno-test** to skip):

```bash
python3 validate.py --input input/require-resource-limits.yaml --output output/converted.yaml --tool nctl
```
