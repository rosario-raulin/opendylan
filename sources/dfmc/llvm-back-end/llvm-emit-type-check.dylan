Module: dfmc-llvm-back-end
Copyright:    Original Code is Copyright (c) 1995-2004 Functional Objects, Inc.
              Additional code is Copyright 2009-2011 Gwydion Dylan Maintainers
              All rights reserved.
License:      See License.txt in this distribution for details.
Warranty:     Distributed WITHOUT WARRANTY OF ANY KIND

/// Type checks

define method emit-type-check
    (back-end :: <llvm-back-end>, object, type :: <value-reference>)
 => ()
  // dynamically computed type -- don't attempt to inline
  let module = back-end.llvm-builder-module;
  let type-ref = emit-reference(back-end, module, type);
  do-emit-type-check(back-end, object, type, type-ref);
end method;

define method emit-type-check
    (back-end :: <llvm-back-end>, object, type :: <object-reference>)
 => ()
  // type is known at compile-time
  let module = back-end.llvm-builder-module;
  let type-value = type.reference-value;
  let type-ref = emit-reference(back-end, module, type-value);
  do-emit-type-check(back-end, object, type-value, type-ref);
end method;

define method emit-type-check
    (back-end :: <llvm-back-end>, object, type == #f) => ()
  // Do nothing
end method;

define method do-emit-type-check
    (back-end :: <llvm-back-end>, object :: <llvm-value>,
     type, type-ref :: <llvm-value>)
 => (true? :: <llvm-value>)
  let module = back-end.llvm-builder-module;

  let error-bb = make(<llvm-basic-block>);
  let result-bb = make(<llvm-basic-block>);

  let cmp = do-emit-instance-cmp(back-end, object, type, type-ref);
  ins--br(back-end, cmp, result-bb, error-bb);

  // Not an instance: throw an error
  ins--block(back-end, error-bb);
  let tce-iep = dylan-value(#"type-check-error").^iep;
  let tce-name = emit-name(back-end, module, tce-iep);
  let tce-global = llvm-builder-global(back-end, tce-name);
  ins--tail-call(back-end, tce-global, vector(object, type-ref),
                 type: $llvm-object-pointer-type,
                 calling-convention:
                   llvm-calling-convention(back-end, tce-iep));
  ins--unreachable(back-end);

  // Instance check succeeded
  ins--block(back-end, result-bb);
  emit-reference(back-end, module, &true)
end method;


/// Instance testing

// Default dynamic instance check using the function stored in the
// instance?-iep slot of the <type> object.
define method do-emit-instance-cmp
    (back-end :: <llvm-back-end>, object :: <llvm-value>,
     type, type-ref :: <llvm-value>)
 => (cmp :: <llvm-value>)
  let module = back-end.llvm-builder-module;
  let word-size = back-end-word-size(back-end);
  let type-class :: <&class> = dylan-value(#"<type>");

  // Retrieve the instance? function slot for this type
  let t-type = op--object-pointer-cast(back-end, type-ref, type-class);
  let instance?-iep-slot-ptr
    = op--getslotptr(back-end, t-type, type-class, #"instance?-iep");
  let iep
    = ins--load(back-end, instance?-iep-slot-ptr, alignment: word-size);

  // Cast as an instance?-iep function type
  let typical-instance?-iep = dylan-value(#"never-instance?-function").^iep;
  let func-type
    = llvm-pointer-to(back-end,
                      llvm-lambda-type(back-end, typical-instance?-iep));
  let iep-func = ins--bitcast(back-end, iep, func-type);

  // Call it and return the truth value
  let result
    = ins--call(back-end, iep-func, vector(object, type-ref),
                calling-convention:
                  llvm-calling-convention(back-end,
                                          typical-instance?-iep));
  ins--icmp-ne(back-end, result, emit-reference(back-end, module, &false));
end method;

define function emit-tag-cmp
    (back-end :: <llvm-back-end>, object :: <llvm-value>, tag :: <integer>)
 => (cmp :: <llvm-value>)
  let object-word
    = ins--ptrtoint(back-end, object, back-end.%type-table["iWord"]);
  let tag-bits = ins--and(back-end, object-word, ash(1, $dylan-tag-bits) - 1);
  ins--icmp-eq(back-end, tag-bits, tag)
end function;

// Compile-time instance check against a <class> instance
define method do-emit-instance-cmp
    (back-end :: <llvm-back-end>, object :: <llvm-value>,
     type :: <&class>, type-ref :: <llvm-value>)
 => (cmp :: <llvm-value>)
  let word-size = back-end-word-size(back-end);
  let m = back-end.llvm-builder-module;
  let entry-bb = back-end.llvm-builder-basic-block;

  case
    type == dylan-value(#"<integer>") =>
      emit-tag-cmp(back-end, object, $dylan-tag-integer);

    type == dylan-value(#"<byte-character>") =>
      emit-tag-cmp(back-end, object, $dylan-tag-character);

    type == dylan-value(#"<unicode-character>") =>
      emit-tag-cmp(back-end, object, $dylan-tag-unichar);

    type == dylan-value(#"<boolean>") =>
      let nonfalse-bb = make(<llvm-basic-block>);
      let result-bb = make(<llvm-basic-block>);

      // Compare against #f
      let false-cmp = ins--icmp-eq(back-end, object,
                                   emit-reference(back-end, m, &false));
      ins--br(back-end, false-cmp, result-bb, nonfalse-bb);

      // Compare against #t
      ins--block(back-end, nonfalse-bb);
      let true-cmp = ins--icmp-eq(back-end, object,
                                  emit-reference(back-end, m, &true));
      ins--br(back-end, result-bb);

      // Result
      ins--block(back-end, result-bb);
      ins--phi(back-end, $llvm-false, entry-bb, true-cmp, nonfalse-bb);

    ^sealed-with-no-subclasses?(type) =>
      let result-bb = make(<llvm-basic-block>);
      let obj-bb = make(<llvm-basic-block>);

      // Check tag to ensure this is a heap object
      let obj-cmp = emit-tag-cmp(back-end, object, $dylan-tag-pointer);
      ins--br(back-end, obj-cmp, obj-bb, result-bb);

      // Retrieve the <mm-wrapper> object from the object header
      ins--block(back-end, obj-bb);
      let object-cast = op--object-pointer-cast(back-end, object, #"<object>");
      let wrapper-slot-ptr
        = ins--gep-inbounds(back-end, object-cast, 0, i32(0));
      let wrapper
        = ins--load(back-end, wrapper-slot-ptr, alignment: word-size);

      // Compare against the class's wrapper
      let type-wrapper = ^class-mm-wrapper(type);
      let wrapper-cmp
        = ins--icmp-eq(back-end, wrapper,
                       emit-wrapper-reference(back-end, m, type-wrapper));
      ins--br(back-end, result-bb);

      // Result
      ins--block(back-end, result-bb);
      ins--phi(back-end, $llvm-false, entry-bb, wrapper-cmp, obj-bb);

    // One of the designated system classes with a reserved subtype bit:
    ^class-subtype-bit(type) ~== 0 =>
      let tag-pointer-bb = make(<llvm-basic-block>);
      let true-bb = make(<llvm-basic-block>);
      let result-bb = make(<llvm-basic-block>);

      // Check for superclasses of one of the tagged classes
      let switch-cases = make(<stretchy-object-vector>);
      local
        method tag-supertype(name :: <symbol>, tag :: <integer>)
          if (^subtype?(dylan-value(name), type))
            add!(switch-cases, tag);
            add!(switch-cases, true-bb);
          end if;
        end method;
      tag-supertype(#"<integer>", $dylan-tag-integer);
      tag-supertype(#"<byte-character>", $dylan-tag-character);
      tag-supertype(#"<unicode-character>", $dylan-tag-unichar);

      // Check tag to determine if this is a heap object
      let object-word
        = ins--ptrtoint(back-end, object, back-end.%type-table["iWord"]);
      let tag-bits
        = ins--and(back-end, object-word, ash(1, $dylan-tag-bits) - 1);
      apply(ins--switch, back-end, tag-bits, result-bb,
            $dylan-tag-pointer, tag-pointer-bb,
            switch-cases);

      // Block for true tag class cases
      unless (empty?(switch-cases))
        ins--block(back-end, true-bb);
        ins--br(back-end, result-bb);
      end unless;

      // Retrieve the <mm-wrapper> object from the object header
      ins--block(back-end, tag-pointer-bb);
      let object-cast = op--object-pointer-cast(back-end, object, #"<object>");
      let wrapper-slot-ptr
        = ins--gep-inbounds(back-end, object-cast, 0, i32(0));
      let wrapper
        = ins--load(back-end, wrapper-slot-ptr, alignment: word-size);

      // Retrieve the mm-wrapper-subtype-mask value (which is a tagged integer)
      let mask-slot-ptr
        = op--getslotptr(back-end, wrapper,
                         #"<mm-wrapper>", #"mm-wrapper-subtype-mask");
      let mask = ins--load(back-end, mask-slot-ptr, alignment: word-size);
      let mask-int
        = ins--ptrtoint(back-end, mask, back-end.%type-table["iWord"]);

      // Compare against the mask for this class type
      let masked
        = ins--and(back-end, mask-int,
                   ash(^class-subtype-bit(type), $dylan-tag-bits));
      let mask-cmp = ins--icmp-ne(back-end, masked, 0);
      ins--br(back-end, result-bb);

      // Result
      ins--block(back-end, result-bb);
      let true-operands
        = if (empty?(switch-cases)) #[] else vector($llvm-true, true-bb) end;
      apply(ins--phi, back-end,
            $llvm-false, entry-bb,
            mask-cmp, tag-pointer-bb,
            true-operands);

    // Something else, use the dynamic check:
    otherwise =>
      next-method();
  end case
end method;

// Compile-time instance check against a <union> instance
define method do-emit-instance-cmp
    (back-end :: <llvm-back-end>, object :: <llvm-value>,
     type :: <&union>, type-ref :: <llvm-value>)
 => (cmp :: <llvm-value>)
  let word-size = back-end-word-size(back-end);
  let class :: <&class> = dylan-value(#"<union>");

  // Basic blocks
  let type2-bb = make(<llvm-basic-block>);
  let result-bb = make(<llvm-basic-block>);

  let union-type = op--object-pointer-cast(back-end, type-ref, class);

  // Check against union-type1
  let type1-slot-ptr
    = op--getslotptr(back-end, union-type, class, #"union-type1");
  let type1-ref = ins--load(back-end, type1-slot-ptr, alignment: word-size);
  let cmp1
    = do-emit-instance-cmp(back-end, object, type.^union-type1, type1-ref);
  let type1-branch-bb = back-end.llvm-builder-basic-block;
  ins--br(back-end, cmp1, result-bb, type2-bb);

  // cmp1 failed, check against union-type2
  ins--block(back-end, type2-bb);
  let type2-slot-ptr
    = op--getslotptr(back-end, union-type, class, #"union-type2");
  let type2-ref = ins--load(back-end, type2-slot-ptr, alignment: word-size);
  let cmp2
    = do-emit-instance-cmp(back-end, object, type.^union-type2, type2-ref);
  let type2-branch-bb = back-end.llvm-builder-basic-block;
  ins--br(back-end, result-bb);

  // Result
  ins--block(back-end, result-bb);
  ins--phi(back-end, $llvm-true, type1-branch-bb, cmp2, type2-branch-bb)
end method;

// Compile-time instance check against a <singleton> instance
define method do-emit-instance-cmp
    (back-end :: <llvm-back-end>, object :: <llvm-value>,
     type :: <&singleton>, type-ref :: <llvm-value>)
 => (cmp :: <llvm-value>);
  let word-size = back-end-word-size(back-end);
  let module = back-end.llvm-builder-module;
  let singleton-ref
    = if (type.^singleton-object)
        emit-indirect-reference(back-end, module, type.^singleton-object);
      else
        let class :: <&class> = dylan-value(#"<singleton>");
        let singleton-type
          = op--object-pointer-cast(back-end, type-ref, class);
        let singleton-object-slot-ptr
          = op--getslotptr(back-end, singleton-type, class,
                           #"singleton-object");
        ins--load(back-end, singleton-object-slot-ptr, alignment: word-size)
      end if;
  ins--icmp-eq(back-end, object, singleton-ref)
end method;

// Compile-time instance check against a <limited-integer> instance
define method do-emit-instance-cmp
    (back-end :: <llvm-back-end>, object :: <llvm-value>,
     type :: <&limited-integer>, type-ref :: <llvm-value>)
 => (cmp :: <llvm-value>)
  let integer-min :: false-or(<integer>) = type.^limited-integer-min;
  let tagged-min
    = integer-min
    & generic/logior(generic/ash(integer-min, $dylan-tag-bits),
                     $dylan-tag-integer);

  let integer-max :: false-or(<integer>) = type.^limited-integer-max;
  let tagged-max
    = integer-max
    & generic/logior(generic/ash(integer-max, $dylan-tag-bits),
                     $dylan-tag-integer);

  // Basic blocks
  let entry-bb = back-end.llvm-builder-basic-block;
  let result-bb = make(<llvm-basic-block>);
  let integer-bb = make(<llvm-basic-block>);
  let result-bb = make(<llvm-basic-block>);

  // Check the tag
  let object-word
    = ins--ptrtoint(back-end, object, back-end.%type-table["iWord"]);
  let tag-bits = ins--and(back-end, object-word, ash(1, $dylan-tag-bits) - 1);
  let tag-cmp = ins--icmp-eq(back-end, tag-bits, $dylan-tag-integer);
  ins--br(back-end, tag-cmp, integer-bb, result-bb);

  // Check the range
  ins--block(back-end, integer-bb);
  case
    // Both limits
    tagged-min & tagged-max =>
      let above-bb = make(<llvm-basic-block>);
      let min-cmp = ins--icmp-sge(back-end, object-word, tagged-min);
      ins--br(back-end, min-cmp, above-bb, result-bb);

      ins--block(back-end, above-bb);
      let max-cmp = ins--icmp-sle(back-end, object-word, tagged-max);
      ins--br(back-end, result-bb);

      ins--block(back-end, result-bb);
      ins--phi(back-end, $llvm-false, entry-bb,
                         $llvm-false, integer-bb,
                         max-cmp, above-bb);

    // Lower limit only
    tagged-min =>
      let min-cmp = ins--icmp-sge(back-end, object-word, tagged-min);
      ins--br(back-end, result-bb);

      ins--block(back-end, result-bb);
      ins--phi(back-end, $llvm-false, entry-bb,
                         min-cmp, integer-bb);

    // Upper limit only
    tagged-max =>
      let max-cmp = ins--icmp-sle(back-end, object-word, tagged-max);
      ins--br(back-end, result-bb);

      ins--block(back-end, result-bb);
      ins--phi(back-end, $llvm-false, entry-bb,
                         max-cmp, integer-bb);

    otherwise =>
      error("Neither min nor max set for limited-integer type check");
  end
end method;
