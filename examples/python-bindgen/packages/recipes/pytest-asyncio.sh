# pytest-asyncio. Pure Python; needs the pytest package too.
#
# 1.1 is the newest that works, as in workerd's Pyodide tests: from 1.2 on
# it closes each test's asyncio.Runner, which cancels and then waits for
# every task on the loop, and the request running pytest is one of them.
VERSION=1.1.0
KIND=pure
WHEELS="pytest-asyncio==$VERSION"
