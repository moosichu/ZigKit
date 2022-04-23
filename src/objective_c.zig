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
pub const IMP = getFunctionPointer(fn (id, SEL, ...) callconv(.C) id);

pub const type_encoding = [:0]const u8;
pub const type_encoding_ptr = ?[*:0]const u8;

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
pub fn encode(comptime objc_type: type) type_encoding {
    return encodeInternal(objc_type, 0);
}

pub fn lookUpClass(name: [:0]const u8) Class {
    return objc_lookUpClass(name);
}

pub fn getClass(name: [:0]const u8) id {
    return objc_getClass(name);
}

pub fn allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) !Class {
    return objc_allocateClassPair(superclass, name, extra_bytes);
}

pub fn disposeClassPair(cls: Class) void {
    return objc_disposeClassPair(cls);
}

// Note: no need for wrappers as these "shouldn't" be called anyway
extern "C" fn objc_getFutureClass(name: ?[*:0]const u8) Class;
extern "C" fn objc_setFutureClass(cls: Class, name: ?[*:0]const u8) void;

extern "C" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
extern "C" fn objc_disposeClassPair(cls: Class) void;
extern "C" fn objc_registerClassPair(cls: Class) void;
// Note: no need for wrappers as this "shouldn't" be called anyway
extern "C" fn objc_duplicateClassPair(original: Class, name: [*:0]const u8, extra_bytes: usize) Class;

extern "C" fn objc_constructInstance(cls: Class, bytes: *anyopaque) id;
extern "C" fn objc_destructInstance(obj: id) *anyopaque;

// extern "C" fn objc_getClassList() void;
// extern "C" fn objc_copyClassList() void;
extern "C" fn objc_lookUpClass(name: [*:0]const u8) Class;
extern "C" fn objc_getClass(name: [*:0]const u8) id;
// extern "C" fn objc_getRequiredClass() void;
// extern "C" fn objc_getMetaClass() void;

// extern "C" fn objc_setAssociatedObject() void;
// extern "C" fn objc_getAssociatedObject() void;
// extern "C" fn objc_removeAssociatedObjects() void;

// extern "C" fn objc_msgSend() void;
// extern "C" fn objc_msgSend_stret () void;
// extern "C" fn objc_msgSendSuper () void;
// extern "C" fn objc_msgSendSuper_stret () void;
// extern "C" fn objc_msgSend() void;
// extern "C" fn objc_msgSend_fpret() void;
// extern "C" fn objc_msgSend_stret() void;
// extern "C" fn objc_msgSendSuper() void;
// extern "C" fn objc_msgSendSuper_stret() void;

// extern "C" fn objc_copyImageNames() void;
// extern "C" fn class_getImageName() void;
// extern "C" fn objc_copyClassNamesForImage() void;

// extern "C" fn objc_getProtocol() void;
// extern "C" fn objc_copyProtocolList() void;
// extern "C" fn objc_allocateProtocol() void;
// extern "C" fn objc_registerProtocol() void;

// extern "C" fn objc_enumerationMutation() void;
// extern "C" fn objc_setEnumerationMutationHandler() void;
// extern "C" fn imp_implementationWithBlock() void;
// extern "C" fn imp_getBlock() void;
// extern "C" fn imp_removeBlock() void;
// extern "C" fn objc_loadWeak() void;
// extern "C" fn objc_storeWeak() void;

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

    pub fn constructInstance(cls: Class, bytes: []u8) id {
        assert(cls.getInstanceSize() <= bytes.len);
        // TODO; check alignment?
        for (bytes) |byte| {
            assert(byte == 0);
        }
        return objc_constructInstance(cls, @ptrCast(*anyopaque, bytes));
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
    extern "C" fn class_copyPropertyList(cls: Class, out_count: *c_uint) ?[*:objc_property_t_Sentinel]objc_property_t_Nonnull;
    extern "C" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: type_encoding_ptr) BOOL; // TODO: wrapper
    extern "C" fn class_getInstanceMethod(cls: Class, name: SEL) Method; // TODO: wrapper
    extern "C" fn class_getClassMethod(cls: Class, name: SEL) Method; // TODO: wrapper
    extern "C" fn class_copyMethodList(cls: Class, out_count: ?*c_uint) ?[*:Method_Sentinel]Method_Nonnull; // TODO: wrapper
    extern "C" fn class_replaceMethod(cls: Class, name: SEL, imp: IMP, types: type_encoding_ptr) IMP; // TODO: wrapper
    extern "C" fn class_getMethodImplementation(cls: Class, name: SEL) IMP; // TODO: wrapper
    extern "C" fn class_getMethodImplementation_stret(cls: Class, name: SEL) IMP; // TODO: wrapper
    extern "C" fn class_respondsToSelector(cls: Class, name: SEL) BOOL; // TODO: wrapper
    extern "C" fn class_addProtocol(cls: Class, protocol: *Protocol) BOOL; // TODO: wrapper
    extern "C" fn class_addProperty(cls: Class, name: [*:0]const u8, attributes: [*]const objc_property_attribute_t, attribute_count: c_uint) BOOL; // TODO: wrapper
    extern "C" fn class_replaceProperty(cls: Class, name: [*:0]const u8, attributes: [*]const objc_property_attribute_t, attribute_count: c_uint) void; // TODO: wrapper
    extern "C" fn class_conformsToProtocol(cls: Class, protocol: *Protocol) BOOL; // TODO:wrapper
    extern "C" fn class_copyProtocolList(cls: Class, out_count: ?*c_uint) [*:Protocol_Sentinel]*allowzero Protocol; // TODO:wrapper
    extern "C" fn class_getVersion(cls: Class) c_int; // TODO:wrapper
    extern "C" fn class_setVersion(cls: Class, version: c_int) void; // TODO:wrapper

    extern "C" fn class_createInstance(cls: Class, extra_bytes: usize) id; // TODO:wrapper
};

pub const id = *allowzero objc_object;
pub const nil: id = @intToPtr(id, 0);
pub const objc_object = extern struct {
    isa: Class,

    pub fn destructInstance(obj: id) *anyopaque {
        return objc_destructInstance(obj);
    }

    // extern "C" fn object_copy() void;
    // extern "C" fn object_dispose() void;
    // extern "C" fn object_setInstanceVariable() void;
    // extern "C" fn object_getInstanceVariable() void;
    // extern "C" fn object_getIndexedIvars() void;
    // extern "C" fn object_getIvar() void;
    // extern "C" fn object_setIvar() void;
    // extern "C" fn object_getClassName() void;
    // extern "C" fn object_getClass() void;
    // extern "C" fn object_setClass() void;

};

pub const Ivar = ?*objc_ivar;
pub const Ivar_Nonnull = *objc_ivar;
pub const objc_ivar = opaque {
    // extern "C" fn ivar_getName() void;
    // extern "C" fn ivar_getTypeEncoding() void;
    // extern "C" fn ivar_getOffset() void;
};

pub const objc_property_t = ?*objc_property;
pub const objc_property_t_Nonnull = *allowzero objc_property;
pub const objc_property_t_Sentinel = @intToPtr(objc_property_t_Nonnull, 0);
pub const objc_property = opaque {
    // extern "C" fn property_getName() void;
    // extern "C" fn property_getAttributes() void;
    // extern "C" fn property_copyAttributeValue() void;
    // extern "C" fn property_copyAttributeList() void;
};

pub const Method = ?*objc_method;
pub const Method_Nonnull = *allowzero objc_method;
pub const Method_Sentinel = @intToPtr(Method_Nonnull, 0);
pub const objc_method = opaque {
    // extern "C" fn method_invoke() void;
    // extern "C" fn method_invoke_stret() void;
    // extern "C" fn method_getName() void;
    // extern "C" fn method_getImplementation() void;
    // extern "C" fn method_getTypeEncoding() void;
    // extern "C" fn method_copyReturnType() void;
    // extern "C" fn method_copyArgumentType() void;
    // extern "C" fn method_getReturnType() void;
    // extern "C" fn method_getNumberOfArguments() void;
    // extern "C" fn method_getArgumentType() void;
    // extern "C" fn method_getDescription() void;
    // extern "C" fn method_setImplementation() void;
    // extern "C" fn method_exchangeImplementations() void;
};

pub const SEL = *objc_selector;
const objc_selector = opaque {
    // extern "C" fn sel_getName() void;
    // extern "C" fn sel_registerName() void;
    // extern "C" fn sel_getUid() void;
    // extern "C" fn sel_isEqual() void;
};

pub const Protocol = opaque {
    // extern "C" fn protocol_addMethodDescription() void;
    // extern "C" fn protocol_addProtocol() void;
    // extern "C" fn protocol_addProperty() void;
    // extern "C" fn protocol_getName() void;
    // extern "C" fn protocol_isEqual() void;
    // extern "C" fn protocol_copyMethodDescriptionList() void;
    // extern "C" fn protocol_getMethodDescription() void;
    // extern "C" fn protocol_copyPropertyList() void;
    // extern "C" fn protocol_getProperty() void;
    // extern "C" fn protocol_copyProtocolList() void;
    // extern "C" fn protocol_conformsToProtocol() void;
};
pub const Protocol_Sentinel = @intToPtr(*allowzero Protocol, 0);

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

// TODO: Figure out how/if it's possible to init comptime datastructures for
// registering Objective C classes at runtime.
// const GlobalRef = struct {
//     comptime objects_to_init: []UntypedInterface = &.{},
// };
// var global_ref: GlobalRef = .{};
// comptime var num_objects_to_init = 0;
// See: https://github.com/ziglang/zig/issues/7396
// https://stackoverflow.com/questions/68555025/global-comptime-var-in-zig

const objects_to_init = block_name: {
    comptime var count: comptime_int = 0;
    comptime var values: []UntypedInterface = &.{};

    const result = struct {
        fn Values() []UntypedInterface {
            return values;
        }

        fn add(comptime value: UntypedInterface) void {
            comptime var new_objects_to_init: [count + 1]UntypedInterface = undefined;
            inline for (values) |object_to_init, index| {
                new_objects_to_init[index] = object_to_init;
            }
            new_objects_to_init[count] = value;
            count += 1;
            values = &new_objects_to_init;
        }
    };

    break :block_name result;
};
// var objects_to_init: []UntypedInterface = &.{};

var NSObject = externInterface("NSObject");

pub fn initRuntime() !void {
    for (objects_to_init.Values()) |object_to_init| {
        try object_to_init.initRuntime();
    }
}

pub fn deinitRuntime() void {
    for (objects_to_init.Values()) |object_to_init| {
        object_to_init.deinitRuntime();
    }
}

pub const objc_property_attribute_t = extern struct {
    name: [*:0]const u8,
    value: [*:0]const u8,
};

pub const UntypedInterface = struct {
    interface_category: InterfaceCategory,
    name: [:0]const u8,
    class_ptr: *Class,

    pub fn initRuntime(self: UntypedInterface) !void {
        switch (self.interface_category) {
            .external => {
                self.class_ptr.* = lookUpClass(self.name);
            },
            .internal => |internal_info| {
                var superclass = lookUpClass(internal_info.superclass_name);
                self.class_ptr.* = try allocateClassPair(superclass, self.name, 0);
                for (internal_info.declaration.properties) |property| {
                    // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtPropertyIntrospection.html#//apple_ref/doc/uid/TP40008048-CH101
                    // See this!
                    // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtPropertyIntrospection.html
                    // https://stackoverflow.com/questions/7819092/how-can-i-add-properties-to-an-object-at-runtime
                    const attributes = [_]objc_property_attribute_t{.{ .name = "", .value = "" }};
                    // TODO: confirm result!
                    _ = self.class_ptr.*.class_addProperty(property.name, &attributes, attributes.len);
                }
            },
        }
    }

    pub fn deinitRuntime(self: UntypedInterface) void {
        switch (self.interface_category) {
            .external => {},
            .internal => {
                disposeClassPair(self.class_ptr.*);
                self.class_ptr.* = Nil;
            },
        }
    }
};

pub const InterfaceCategoryTag = enum {
    internal,
    external,
};

const InterfaceCategory = union(InterfaceCategoryTag) {
    internal: struct {
        superclass_name: [:0]const u8,
        declaration: Declaration,
    },
    external,
};

pub fn Interface(comptime name_arg: [:0]const u8, interface_category: InterfaceCategory) type {
    return struct {
        const _interface_category: InterfaceCategory = interface_category;
        const _name: [:0]const u8 = name_arg;
        const _type: type = @This();
        var _class: Class = Nil;

        pub fn untypedInterface() UntypedInterface {
            return .{
                .interface_category = _interface_category,
                .name = _name,
                .class_ptr = &_class,
            };
        }

        pub fn initRuntime(self: *@This()) !void {
            _ = self;
            untypedInterface().initRuntime();
        }

        pub fn Type(comptime self: *@This()) type {
            _ = self;
            return _type;
        }

        pub fn class(self: @This()) Class {
            _ = self;
            return _class;
        }

        pub fn register() void {
            objects_to_init.add(comptime untypedInterface());
        }
    };
}

pub fn externInterface(comptime name: [:0]const u8) Interface(name, .external) {
    Interface(name, .external).register();
    return .{};
}

pub fn interface(comptime name: [:0]const u8, comptime declaration: Declaration, comptime Parent: type) Interface(name, InterfaceCategory{ .internal = .{ .superclass_name = Parent._name, .declaration = declaration } }) {
    const InterfaceType = Interface(name, InterfaceCategory{ .internal = .{ .superclass_name = Parent._name, .declaration = declaration } });
    InterfaceType.register();
    return .{};
}

const Property = struct {
    const Type = enum {
        int,
        long,
    };
    type: Type,
    name: [:0]const u8,
};

const Declaration = struct {
    properties: []const Property,
};

var MyClass = interface("MyClass", .{
    .properties = &[_]Property{.{ .type = .int, .name = "test_property" }},
}, NSObject.Type());

test "Objects" {
    try initRuntime();
    defer deinitRuntime();
    try testing.expect(NSObject.class() != Nil);
    try testing.expect(MyClass.class() != Nil);
    try testing.expect(MyClass.class().getSuperclass() == NSObject.class());
}
