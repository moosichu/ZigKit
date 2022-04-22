const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;

const getFunctionPointer = @import("shared.zig").getFunctionPointer;

// Bindings for the objective-c runtime on Apple devices.
// For further documentation see:
// - https://developer.apple.com/documentation/objectivec?language=objc
// - https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Introduction/Introduction.html#//apple_ref/doc/uid/TP40008048

// We use allow zero because all of the class interactions for objc_class are
// well-defined for the "Nil" class which is defined to be 0
pub const BOOL = i8;
pub const YES: BOOL = 1;
pub const NO: BOOL = 0;
pub const SEL = *objc_selector;
const objc_selector = opaque {};
pub const IMP = getFunctionPointer(fn (id, SEL, ...) callconv(.C) id);

fn encodeSize(comptime objc_type: type, indirection: comptime_int) comptime_int {
    const type_info = @typeInfo(objc_type);
    switch (type_info) {
        .Int, .Float, .Bool => return 1,
        .Struct => |struct_info| {
            if (struct_info.layout != .Extern) {
                @compileError(@tagName(struct_info.layout) ++ " struct not supported - please declare as extern!");
            }

            comptime var result = @typeName(objc_type).len + 2;
            if (indirection <= 1) {
                result += 1;
                inline for (struct_info.fields) |field| {
                    result += encodeSize(field.field_type, indirection + 1);
                }
            }
            return result;
        },
        .Pointer => |pointer_info| {
            if (pointer_info.child == objc_object) {
                // maps to @
                return 1;
            }
            switch (@typeInfo(pointer_info.child)) {
                // char * (string) type is special!
                .Int => |int_info| switch (int_info.bits) {
                    @bitSizeOf(u8) => return 1,
                    else => {},
                },
                .Opaque, .Void => return 1,
                else => {},
            }
            return 1 + encodeSize(pointer_info.child, indirection + 1);
        },
        else => {
            @compileError("Cannot encode type " ++ @typeName(objc_type) ++ ".");
        },
    }
}

fn copyArray(comptime left_slice: anytype, comptime right_slice: anytype) void {
    for (right_slice) |char, index| {
        left_slice[index] = char;
    }
}

fn encodeLiteral(comptime objc_type: type, comptime len: comptime_int, indirection: comptime_int) *const [len:0]u8 {
    const type_info = @typeInfo(objc_type);

    switch (type_info) {
        .Int => |int_info| {
            switch (int_info.signedness) {
                .signed => switch (int_info.bits) {
                    @bitSizeOf(i8) => return "c",
                    @bitSizeOf(c_int) => return "i",
                    @bitSizeOf(c_short) => return "s",
                    @bitSizeOf(c_long) => return "l",
                    @bitSizeOf(c_longlong) => return "q",
                    else => @compileError("Unsupported integer bit count."),
                },
                .unsigned => switch (int_info.bits) {
                    @bitSizeOf(u8) => return "C",
                    @bitSizeOf(c_uint) => return "I",
                    @bitSizeOf(c_ushort) => return "S",
                    @bitSizeOf(c_ulong) => return "L",
                    @bitSizeOf(c_ulonglong) => return "Q",
                    else => @compileError("Unsupported integer bit count."),
                },
            }
        },
        .Float => |float_info| switch (float_info.bits) {
            @bitSizeOf(f32) => return "f",
            @bitSizeOf(f64) => return "d",
        },
        .Bool => return "B",
        .Void => "v",
        // TODO: a character string char * is a special case!
        // TODO: a statically typed (id) object
        // TODO: class object
        // TODO: a method selector
        // TODO: an array
        .Struct => |struct_info| comptime {
            if (indirection <= 1) {
                comptime var result: [len:0]u8 = undefined;
                const type_string = "{" ++ @typeName(objc_type) ++ "=";
                copyArray(&result, type_string);
                comptime var current_index = type_string.len;
                inline for (struct_info.fields) |field| {
                    const sub_encode = encodeInternal(field.field_type, indirection + 1);
                    copyArray(result[current_index..], sub_encode);
                    current_index += sub_encode.len;
                }
                copyArray(result[current_index..], "}");
                return &result;
            }
            return "{" ++ @typeName(objc_type) ++ "}";
        },
        .Pointer => |pointer_info| {
            if (pointer_info.child == objc_object) {
                return "@";
            }
            switch (@typeInfo(pointer_info.child)) {
                // char * (string) type is special!
                .Int => |int_info| switch (int_info.bits) {
                    @bitSizeOf(u8) => return "*",
                    else => {},
                },
                .Opaque, .Void => return "?",
                else => {},
            }
            return "^" ++ encodeInternal(pointer_info.child, indirection + 1);
        },
        // TODO: a union
        // TODO: a bitfield
        else => {},
    }

    // Unencodable type - all errors should have been handled in encodeSize with
    // nice messages!
    unreachable;
}

fn encodeInternal(comptime objc_type: type, indirection: comptime_int) [:0]const u8 {
    const encode_size = encodeSize(objc_type, indirection);
    return encodeLiteral(objc_type, encode_size, indirection);
}

/// Encode a type as an objective-c type string
/// See: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html#//apple_ref/doc/uid/TP40008048-CH100
pub fn encode(comptime objc_type: type) [:0]const u8 {
    return encodeInternal(objc_type, 0);
}

pub const Class = *allowzero objc_class;
pub const Nil: Class = @intToPtr(Class, 0);
pub const objc_class = opaque {
    pub fn getName(cls: Class) [:0]const u8 {
        const result = class_getName(cls);
        return mem.sliceTo(result, 0);
    }

    pub fn getSuperclass(cls: Class) Class {
        return class_getSuperclass(cls);
    }

    pub fn isMetaClass(cls: Class) bool {
        const result = class_isMetaClass(cls);
        if (result == YES) {
            return true;
        }
        if (result == NO) {
            return false;
        }
        unreachable;
    }

    pub fn getInstanceSize(cls: Class) usize {
        return class_getInstanceSize(cls);
    }

    pub fn getProperty(cls: Class, name: [:0]const u8) objc_property_t {
        return class_getProperty(cls, name);
    }

    // Note: result must be freed with free()
    pub fn copyPropertyList(cls: Class) []objc_property_t_Nonnull {
        var out_count: c_uint = undefined;
        const result = class_copyPropertyList(cls, &out_count);
        if (out_count == 0) {
            assert(result == null);
            return &[_]objc_property_t_Nonnull{};
        }
        assert(result != null);
        return result.?[0..out_count];
    }

    extern "C" fn class_getName(cls: Class) [*:0]const u8;
    extern "C" fn class_getSuperclass(cls: Class) Class;
    extern "C" fn class_isMetaClass(cls: Class) BOOL;
    extern "C" fn class_getInstanceSize(cls: Class) usize;
    extern "C" fn class_getInstanceVariable(cls: Class, name: [*:0]u8) Ivar; // TODO: wrapper
    extern "C" fn class_getClassVariable(cls: Class, name: [*:0]u8) Ivar; // TODO: wrapper
    extern "C" fn class_addIvar(cls: Class, name: [*:0]u8, size: usize, alignment: u8, types: [*:0]u8) BOOL; // TODO: wrapper
    extern "C" fn class_copyIvarList(cls: Class, out_count: *c_uint) ?[*:0]Ivar_Nonnull; // TODO: wrapper
    extern "C" fn class_getIvarLayout(cls: Class) [*]const u8; // TODO: proper return type & wrapper
    extern "C" fn class_setIvarLayout(cls: Class, [*]const u8) void; // TODO: proper return type & wrapper
    extern "C" fn class_getWeakIvarLayout(cls: Class) [*]const u8; // TODO: proper return type & wrapper
    extern "C" fn class_setWeakIvarLayout(cls: Class, [*]const u8) void; // TODO: proper return type & wrapper
    extern "C" fn class_getProperty(cls: Class, name: [*:0]const u8) objc_property_t;
    extern "C" fn class_copyPropertyList(cls: Class, out_count: *c_uint) ?[*:objc_property_t_sentinel]objc_property_t_Nonnull;
    extern "C" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: ?[*:0]u8) BOOL;

    // TODO;
    // extern "C" fn class_getInstanceMethod
    // extern "C" fn class_getClassMethod
    // extern "C" fn class_copyMethodList
    // extern "C" fn class_replaceMethod
    // extern "C" fn class_getMethodImplementation
    // extern "C" fn class_getMethodImplementation_stret
    // extern "C" fn class_respondsToSelector
    // extern "C" fn class_addProtocol
    // extern "C" fn class_addProperty
    // extern "C" fn class_replaceProperty
    // extern "C" fn class_conformsToProtocol
    // extern "C" fn class_copyProtocolList
    // extern "C" fn class_getVersion
    // extern "C" fn class_setVersion

    extern "C" fn class_createInstance(cls: Class, extra_bytes: usize) id;
};

pub const id = *allowzero objc_object;
pub const nil: id = @intToPtr(id, 0);
pub const objc_object = extern struct {
    isa: Class,

    pub fn constructInstance(cls: Class, bytes: []u8) id {
        assert(cls.getInstanceSize() <= bytes.len);
        // TODO; check alignment?
        for (bytes) |byte| {
            assert(byte == 0);
        }
        return objc_constructInstance(cls, @ptrCast(*anyopaque, bytes));
    }

    pub fn destructInstance(obj: id) *anyopaque {
        return objc_destructInstance(obj);
    }

    extern "C" fn objc_constructInstance(cls: Class, bytes: *anyopaque) id;
    extern "C" fn objc_destructInstance(obj: id) *anyopaque;
};

pub const Ivar = ?*objc_ivar;
pub const Ivar_Nonnull = *objc_ivar;
pub const objc_ivar = opaque {};

pub const objc_property_t = ?*objc_property;
pub const objc_property_t_Nonnull = *allowzero objc_property;
pub const objc_property_t_sentinel = @intToPtr(objc_property_t_Nonnull, 0);
pub const objc_property = opaque {};

test {
    _ = testing.refAllDecls(@This());
    _ = testing.refAllDecls(objc_selector);
    _ = testing.refAllDecls(objc_class);
    _ = testing.refAllDecls(objc_object);
    _ = testing.refAllDecls(objc_ivar);
}

test "encode" {
    try testing.expectEqualStrings(encode(i8), "c");
    try testing.expectEqualStrings(encode(u8), "C");
    try testing.expectEqualStrings(encode(c_long), "l");
    {
        const test_struct = extern struct {
            a: c_uint,
        };
        try testing.expectEqualStrings(encode(test_struct), "{test_struct=I}");
    }
    {
        const example = extern struct {
            an_object: id,
            a_string: [*:0]u8,
            an_int: i32,
        };
        try testing.expectEqualStrings(encode(example), "{example=@*i}");
        try testing.expectEqualStrings(encode(*example), "^{example=@*i}");
        // testing layers of indirection!
        try testing.expectEqualStrings(encode(**example), "^^{example}");
    }
}

test "Nil tests" {
    try testing.expectEqualSentinel(u8, 0, Nil.getName(), "nil");
    try testing.expectEqual(Nil.getSuperclass(), Nil);
    try testing.expectEqual(Nil.isMetaClass(), false);
    try testing.expectEqual(Nil.getInstanceSize(), 0);
    try testing.expectEqual(Nil.getProperty(""), null);
    try testing.expectEqualSlices(objc_property_t_Nonnull, Nil.copyPropertyList(), &.{});
}
