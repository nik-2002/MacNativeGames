"""Recognize a static ARM64 jump-table address within one function."""
import re


def table_base(instructions, before, register):
    """Resolve an ADRP+ADD producer, stopping at any intervening clobber.

    Compilers can hoist the producer far above a dispatch block. Search the
    function prefix, rather than a fixed instruction window. A W-register write
    clobbers the corresponding X register too; unsupported producers fail closed.
    """
    low = None
    canonical = lambda name: {'lr': 'x30', 'fp': 'x29'}.get(name, name)
    for instruction in reversed(instructions[:before]):
        writes = {canonical(instruction.reg_name(r)) for r in instruction.regs_access()[1]}
        if register not in writes and 'w' + register[1:] not in writes:
            continue
        # A compiler may park the table address in another scratch register,
        # reuse the original, then copy the address back before dispatch.
        copy = re.fullmatch(rf'{register}, (x\d+)', instruction.op_str)
        if instruction.mnemonic == 'mov' and copy:
            register = copy.group(1)
            continue
        match = re.fullmatch(rf'{register}, {register}, #(0x[0-9a-f]+|\d+)', instruction.op_str)
        if low is None and instruction.mnemonic == 'add' and match:
            low = int(match.group(1), 0)
            continue
        if low is not None and instruction.mnemonic == 'adrp' and instruction.op_str.startswith(register + ','):
            return instruction.operands[1].imm + low
        return None
    return None
