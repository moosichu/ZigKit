const builtin = @import("builtin");

// A workaround until stage 2 is shipped
pub fn getFunctionPointer(comptime function_type: type) type {
    return switch (builtin.zig_backend) {
        .stage1 => function_type,
        else => *const function_type,
    };
}
