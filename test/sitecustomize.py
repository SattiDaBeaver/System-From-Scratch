import inspect
from cocotb.clock import Clock


# cocotb 1.9+ uses `units=...` while this project still calls
# `Clock(..., unit="ns")` in many tests. Translate the older keyword
# automatically so the existing test suite keeps working without editing
# every test file.
if "units" in inspect.signature(Clock.__init__).parameters and "unit" not in inspect.signature(Clock.__init__).parameters:
    _orig_clock_init = Clock.__init__

    def _clock_init_compat(self, signal, period, *args, **kwargs):
        if "unit" in kwargs and "units" not in kwargs:
            kwargs["units"] = kwargs.pop("unit")
        return _orig_clock_init(self, signal, period, *args, **kwargs)

    Clock.__init__ = _clock_init_compat
