#include "util.h"

int main(void) {
	int numbers[] = {1, 2, 3, 4, 5};
	size_t count = sizeof(numbers) / sizeof(numbers[0]);
	int unused = 0;
	printf("sum = %d\n", sum(numbers, count));
	printf("max = %d\n", max_value(numbers, count));
	return 0;
}
