# Rails Test Speed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the default Rails test loop use the fastest verified safe configuration while preserving explicit N+1 and coverage verification modes.

**Architecture:** Use Rails' built-in process parallelization with six workers, which was the fastest measured setting on the development machine. Remove manual GC control, keep coverage opt-in, make Prosopite opt-in locally and mandatory in CI, and eliminate test log I/O that does not contribute to assertions.

**Tech Stack:** Rails 8.1.3, Minitest 6, PostgreSQL, SimpleCov, Prosopite, GitHub Actions

---

### Task 1: Simplify and accelerate the local test harness

**Files:**
- Modify: `test/test_helper.rb`

- [x] **Step 1: Keep SimpleCov behind `COVERAGE`**

Retain the existing conditional SimpleCov initialization so ordinary local runs do not collect coverage.

- [x] **Step 2: Use six process workers by default**

Keep the macOS fork-safety fallback, but change the fork-enabled default to:

```ruby
parallelize(workers: 6)
```

Rails continues to honor `PARALLEL_WORKERS` when a caller needs an override.

- [x] **Step 3: Remove manual GC management**

Delete `DEFERRED_GC_THRESHOLD`, `@@last_gc_run`, the `GC.disable` call, and `reconsider_gc_deferment`. Ruby's normal GC was faster and substantially more stable in the benchmark.

- [x] **Step 4: Make per-test Prosopite scanning explicit**

Wrap the Prosopite hooks in:

```ruby
if ENV["N_PLUS_ONE"] == "1"
  setup { Prosopite.scan }
  teardown { Prosopite.finish }
end
```

### Task 2: Remove test logging overhead

**Files:**
- Modify: `config/environments/test.rb`

- [x] **Step 1: Load Prosopite only in N+1 mode**

Guard the Prosopite `after_initialize` configuration with `ENV["N_PLUS_ONE"] == "1"`.

- [x] **Step 2: Disable query tagging and lower log verbosity**

Configure:

```ruby
config.active_record.verbose_query_logs = false
config.active_record.query_log_tags_enabled = false
config.log_level = :fatal
```

### Task 3: Preserve N+1 verification in CI

**Files:**
- Modify: `.github/workflows/ci.yml`

- [x] **Step 1: Set the verified CI test mode**

Add these variables to the test step:

```yaml
PARALLEL_WORKERS: "6"
N_PLUS_ONE: "1"
```

This keeps N+1 detection mandatory while local runs remain fast.

### Task 4: Keep scanner-specific tests compatible with both modes

**Files:**
- Modify: `test/models/events/event_media_test.rb`

- [x] **Step 1: Guard the intentional Prosopite pause**

The gallery-cap test creates twenty records as setup and intentionally pauses N+1 scanning around that setup. Guard its `Prosopite.finish` and `Prosopite.scan` calls with:

```ruby
ENV["N_PLUS_ONE"] == "1"
```

The model assertion remains identical in fast and N+1 modes.

### Task 5: Verify behavior and performance

**Files:**
- Verify: `test/test_helper.rb`
- Verify: `config/environments/test.rb`
- Verify: `.github/workflows/ci.yml`

- [x] **Step 1: Run the fast local suite**

```bash
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bundle exec rails test --seed 4242
```

Expected: six workers, 1,138 tests, zero failures and zero errors.

- [x] **Step 2: Run N+1 verification**

```bash
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES N_PLUS_ONE=1 bundle exec rails test --seed 4242
```

Expected: six workers, Prosopite enabled, zero failures and zero errors.

- [x] **Step 3: Run serial coverage verification**

```bash
COVERAGE=1 PARALLEL_WORKERS=1 bundle exec rails test --seed 4242
```

Expected: one worker, complete SimpleCov coverage, zero failures and zero errors.

- [x] **Step 4: Run RuboCop**

```bash
bundle exec rubocop test/test_helper.rb config/environments/test.rb
```

Expected: no offenses.
