alias t := test
alias twin := test_win
alias b := build
alias bwin := build_win

# Run the internal testz tests to check that we see the correct output for failures (captured and compared within the tests themselves).
test *OPTS:
	zig build tests -- {{OPTS}}

test_win *OPTS:
	zig build -Dtarget=x86_64-windows-gnu tests -- {{OPTS}}

build *OPTS:
	zig build docs {{OPTS}}

build_win *OPTS:
	zig build -Dtarget=x86_64-windows-gnu docs {{OPTS}}