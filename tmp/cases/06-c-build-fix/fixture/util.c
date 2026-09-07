#include "util.h"

int sum(const int *values, size_t count) {
	int total = 0;
	for (size_t i = 0; i < count; i++) {
		total += values[i];
	}
	return total;
}

int max_value(const int *values, size_t count) {
	int best = values[0];
	for (size_t i = 1; i < count; i++) {
		if (values[i] > best) {
			best = values[i];
		}
	}
	return best;
}
