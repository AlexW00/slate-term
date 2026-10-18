"""Research only: private PTY endpoints, no shell/app or user device access."""
import os
import select
import tty

master, slave = os.openpty()
try:
    tty.setraw(slave)

    def receive(fd, expected):
        assert select.select([fd], [], [], 1)[0], "PTY read timed out"
        actual = os.read(fd, 4096)
        assert actual == expected, (actual, expected)

    os.write(slave, b"OUTPUT")
    receive(master, b"OUTPUT")
    print("PASS: slave writes are output readable at master")
    os.write(master, b"INPUT")
    receive(slave, b"INPUT")
    print("PASS: master writes are input readable at slave")

    # No implicit ordering barrier: two output writers can produce either order.
    duplicate_slave = os.open(os.ttyname(slave), os.O_WRONLY | os.O_NOCTTY)
    try:
        os.write(slave, b"CHILD ")
        os.write(duplicate_slave, b"HOST")
        receive(master, b"CHILD HOST")
        os.write(duplicate_slave, b"HOST ")
        os.write(slave, b"CHILD")
        receive(master, b"HOST CHILD")
        print("PASS: opening slave again supplies no host-before-child ordering")
    finally:
        os.close(duplicate_slave)
finally:
    os.close(master)
    os.close(slave)
