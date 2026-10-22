const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn subtract(x: i32, y: i32) i32 {
    return x - y;
}

pub fn multiply(a: i32, b: i32) i32 {
    const result = a * b;
    return result;
}

fn main() void {
    const sum = add(1, 2);
    const diff = subtract(5, 3);
    const prod = multiply(2, 3);
}
