export UV_CACHE_DIR ?= $(CURDIR)/.cache/uv
export PRE_COMMIT_HOME ?= $(CURDIR)/.cache/pre-commit
export CLANG_MODULE_CACHE_PATH ?= $(CURDIR)/.cache/clang
export SWIFTPM_MODULECACHE_OVERRIDE ?= $(CURDIR)/.cache/swift
SWIFT_FLAGS ?= --cache-path .cache/swiftpm/cache --config-path .cache/swiftpm/config --security-path .cache/swiftpm/security

.PHONY: setup build check run test-optimized test-tsan

setup:
	uv sync --project tools --locked
	$(MAKE) build

build:
	swift build $(SWIFT_FLAGS) -Xswiftc -warnings-as-errors

check:
	$(MAKE) build
	swift build $(SWIFT_FLAGS) -c release -Xswiftc -warnings-as-errors
	$(MAKE) -C driver
	swift test $(SWIFT_FLAGS)
	$(MAKE) test-optimized
	$(MAKE) test-tsan
	xcrun swift-format lint --strict -r Sources Tests
	cd tools && uv run --locked ruff format --check .
	cd tools && uv run --locked ruff check .
	cd tools && uv run --locked pyright
	cd tools && uv run --locked --group site pytest
	uv run --project tools --locked pre-commit run --all-files

# Allocation counts and time bounds on the frame path only mean something with optimisation on.
test-optimized:
	swift test $(SWIFT_FLAGS) -c release -Xswiftc -enable-testing --build-path .build/optimized \
		--filter FramePathThreads

# The golden streams take minutes under the sanitizer and add no thread interleaving.
test-tsan:
	swift test $(SWIFT_FLAGS) --sanitize=thread --build-path .build/tsan \
		--filter UntunnelEngineTests --skip GoldenParity

run:
	swift run $(SWIFT_FLAGS) untunnel

.PHONY: demo-gif
demo-gif:
	uv run --project tools --locked --group site python -m untunnel_tools.site.demo_gif
