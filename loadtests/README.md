# Staging performance gate

`run_load.py` sends a fixed-rate, bounded-concurrency workload to the
authenticated synchronous inference endpoint. It fails unless all configured
error-rate, client P95 latency, throughput, and request-count checks pass.

The JSON report contains aggregate latency, status, error-class, and throughput
data only. It never contains the API key, prompt, model response, or request
body. The scheduler uses a bounded queue so an overloaded target cannot cause
unbounded memory growth in the load generator.

Run against an HTTPS staging origin:

```bash
export API_AUTH_TOKEN='<32-128 character staging token>'
python -m loadtests.run_load \
  --url https://staging.example.com \
  --duration-seconds 120 \
  --requests-per-second 2 \
  --concurrency 10
unset API_AUTH_TOKEN
```

Prefer the protected `Staging Performance Gate` workflow. It verifies that the
requested revision has a successful staging promotion and is still the exact
image running in ECS before generating traffic. Load tests invoke Bedrock and
therefore incur model, ALB, logging, and related AWS charges.
