CC ?= cc
CFLAGS ?= -Wall -Wextra -Werror -std=c11

app: main.o util.o
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c util.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f app *.o

.PHONY: clean
