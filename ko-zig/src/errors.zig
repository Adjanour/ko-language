pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
    InvalidCharacter,
    Overflow,
    InvalidBase,
};

pub const TypeError = error{
    UndefinedName,
    TypeMismatch,
    OccursCheck,
    UnknownConstructor,
    UnknownType,
    OutOfMemory,
};
