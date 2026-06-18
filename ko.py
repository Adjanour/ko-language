#!/usr/bin/env python3
"""Kō Compiler - Main entry point"""

import sys
import os
import subprocess
from lexer import tokenize, LexerError
from parser import parse, ParseError
from codegen import generate_c


def compile_ko(source: str, output_name: str = "output"):
    """Compile Kō source to C and build"""
    try:
        # Tokenize
        tokens = tokenize(source)

        # Parse
        program = parse(tokens)

        # Generate C
        c_code = generate_c(program)

        # Write C file
        c_file = f"{output_name}.c"
        with open(c_file, 'w') as f:
            f.write(c_code)

        print(f"Generated {c_file}")

        # Compile with gcc
        exe_file = output_name
        result = subprocess.run(
            ["gcc", "-o", exe_file, c_file, "-lm"],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            print(f"C compilation failed:\n{result.stderr}")
            return False

        print(f"Compiled to {exe_file}")
        return True

    except LexerError as e:
        print(f"Lexer error: {e}")
        return False
    except ParseError as e:
        print(f"Parse error: {e}")
        return False
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        return False


def repl():
    """Interactive REPL"""
    print("Kō REPL (v0.1)")
    print("Type expressions, 'let x = ...' for bindings, ':q' to quit")
    print()

    definitions = []

    while True:
        try:
            line = input("ko> ").strip()
            if not line:
                continue
            if line == ':q':
                break

            # Tokenize and parse
            tokens = tokenize(line)
            program = parse(tokens)

            # Add to definitions
            definitions.extend(program.definitions)

            # Generate and compile a temp program
            full_program = type('Program', (), {'definitions': definitions})()
            c_code = generate_c(full_program)

            # Write and compile
            with open('/tmp/ko_repl.c', 'w') as f:
                f.write(c_code)

            result = subprocess.run(
                ["gcc", "-o", "/tmp/ko_repl", "/tmp/ko_repl.c", "-lm"],
                capture_output=True,
                text=True
            )

            if result.returncode != 0:
                print(f"Compilation error:\n{result.stderr}")
                continue

            # Run
            result = subprocess.run(
                ["/tmp/ko_repl"],
                capture_output=True,
                text=True
            )

            if result.returncode != 0:
                print(f"Runtime error:\n{result.stderr}")
            elif result.stdout:
                print(result.stdout, end='')

        except (LexerError, ParseError) as e:
            print(f"Error: {e}")
        except KeyboardInterrupt:
            print("\nBye!")
            break
        except EOFError:
            break


def main():
    if len(sys.argv) < 2:
        repl()
    elif sys.argv[1] == '-e':
        # Execute inline code
        expr = sys.argv[2]
        # If it already has top-level definitions, use as-is
        if any(expr.strip().startswith(kw) for kw in ['fn ', 'type ', 'let ']):
            source = expr
        elif any(expr.strip().startswith(kw) for kw in ['print', 'inspect', 'println', 'panic']):
            # These are expressions that need to be wrapped in main
            source = f"fn main =\n  {expr}"
        else:
            source = f"fn main =\n  {expr}"
        output = sys.argv[3] if len(sys.argv) > 3 else '/tmp/ko_out'
        if compile_ko(source, output):
            subprocess.run([output])
    else:
        # Compile file
        filename = sys.argv[1]
        output = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(filename)[0]
        with open(filename) as f:
            source = f.read()
        compile_ko(source, output)


if __name__ == '__main__':
    main()
