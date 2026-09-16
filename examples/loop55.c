int main(void) {
    int sum = 0;
    int i;

    for (i = 1; i <= 10; i++) {
        sum += i;
    }

    while (1) {
        // Busy wait to keep the program running on the target.
    }

    return sum;
}
