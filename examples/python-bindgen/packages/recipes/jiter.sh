# jiter: the JSON parser behind pydantic and the OpenAI SDK (PyO3).
VERSION=0.19.0
KIND=pyo3
OPT_LEVEL=z
MODULES="jiter:PyInit_jiter"
build_native() { default_pyo3 jiter_python crates/jiter-python; }
