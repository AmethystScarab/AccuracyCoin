# AccuracyCoin PAL

AccuracyCoin PAL is the PAL conversion of AccuracyCoin, a large collection of NES accuracy tests on a single NROM cartridge. It lives on the `AccuracyCoinPAL` branch and targets a PAL NES with an RP2C07 PPU and RP2A07 CPU/APU.

The shared frame/VBlank/APU timing paths use PAL timing. PAL-specific rewrites cover the known CPU, PPU, and APU differences between NTSC and PAL behavior.

The central PAL difference for the DMA tests: **a 2A07 DMC DMA only halts the CPU on an opcode fetch** (NESdev forum, "PAL DMA behavior"). The 2A03 tests observed DMAs through data reads (`LDA $4000`, a DMA in the middle of an instruction), which cannot happen on a 2A07, so those tests were rebuilt around what a 2A07 can show:

- an opcode fetched from open bus that a DMA turns into a BRK (the "probe"),
- a program held on the stack and run by PLAs in open bus, which places any opcode at `$4001`–`$4014` with no DMA at all,
- cycle counts measured against the frame IRQ or against the next DMC DMA.

The rebuilt slots are `$45B`, `$45C`, `$460`–`$463`, `$46A`, `$46C`, `$46D`, `$477`–`$479`, `$490`, `$496`, `$497` and `$498`. The assembly source is authoritative for what each one checks; every rebuilt test carries a STATUS comment and its derivation.

Every original test runs in a PAL form. Where a 2C02 test samples one dot at a time, the PAL form samples every 1.6 dots (a PAL frame is 33247.5 CPU cycles) and its key checks what those samples must show; each such section says how.

## Building

Assemble `AccuracyCoinPAL.asm` with the original `Sprites.pcx` and `Tiles.pcx` assets using NESASM 3.01 or NESASM CE. Stock NESASM keeps only the first 31 characters of a label; every label in the source is unique within 31 characters.

This ROM currently has 147 tests. These tests print "PASS" or "FAIL" on screen, and in the event of a failure, this ROM also provides an error code. In addition to those tests, this ROM also has 5 tests labeled "DRAW", which don't actually test for anything; rather, they simply print information on screen.

Here's an example of the menu in this ROM shown on an emulator failing a test, passing others, a few tests on screen haven't been run yet, and a test marked to be skipped. (The cursor is currently next to the "Dummy Read Cycles" test.)

<img width="512" height="480" alt="AccuracyCoin_Example" src="https://github.com/user-attachments/assets/a8b9aecf-7d9c-49ad-9c1c-15f4fd60705a" />

# Navigating the menus
Use the D-Pad to move the cursor up or down.  
Pressing A will run the highlighted test.  
Pressing B will mark the highlighted test to be skipped. You can press B again to un-mark the test. This is useful if any tests are crashing the console or emulator and you still want to see the table of results.  
If the cursor is at the top of the page (highlighting the current page index), pressing left and right will scroll to a new page of tests.  
If the cursor is at the top of the page (highlighting the current page index), pressing A will run all tests on the page.  
If the cursor is at the top of the page (highlighting the current page index), pressing B will mark all tests on the page to be skipped.  
If the cursor is at the top of the page (highlighting the current page index), pressing Start will run all tests on the ROM, and then draw a table showing the results of every test.

Examples:

<img width="538" height="240" alt="AccuracyCoin_ResultScreen" src="https://github.com/user-attachments/assets/902c6cdb-7dfa-4625-b67b-6959c9b11634" />

Any test with multiple acceptable passing behaviors will be drawn with a light blue number over it.

# The Debug Menu

After running a test, you can press "Select" to reveal this menu:

<img width="512" height="480" alt="AccuracyCoin_DebugScreen" src="https://github.com/user-attachments/assets/ffc657d7-def4-44f1-a962-2815c9968c96" />

This menu will print several bytes on screen and can be useful for debugging certain tests in a situation where you don't have a way to view everything in RAM. I suggest simply using some form of memory viewer if possible.

This menu does not apply to every test in the ROM, as many tests don't write anything to RAM, or the values written aren't relevant for what went wrong.

The topmost row will print the values from address $20 to $2F, which are values used in the Unofficial Instruction tests.  
The second row will print the values from $50 to $6F, which are used in a handful of tests.  
The remaining 8 rows will print every byte from address $500 to $5FF, which is typically where a test will store any bytes needed for it.

Here's a color-coded version of that image, with boxes around each byte:

<img width="512" height="480" alt="AccuracyCoin_DebugScreen_Labeled" src="https://github.com/user-attachments/assets/8758b318-b413-4bd9-9b2c-f37ec18b75a0" />

# Error Codes
For more information, I recommend reading the fully commented assembly code for the test.

> **PAL note:** the lists below are the error codes this ROM reports; each entry is the description in the source's `;;; Test N [name]` marker, or the original AccuracyCoin text where the test is unchanged.

## Page 1: CPU Behavior

### ROM is not Writable
  1: Writing to ROM should not overwrite the byte in ROM.  

### RAM Mirroring
  1: Reading from a 13-bit mirror of an address in RAM should have the same value as the 11-bit address.  
  2: Writing to a 13-bit mirror of an address in RAM should write to the 11-bit address.  

### PC Wraparound
  1: Executing address $FFFF should read addresses $0000 and $0001 as the operands.  

### The Decimal Flag
  1: The 6502 "Binary Coded Decimal" flag should not affect the ADC or SBC instructions on the NES.  
  2: Despite this flag not working, it still gets pushed in a PHP/BRK instruction.  

### The B Flag
  1: The B flag of the 6502 processor flags should be set by PHP.  
  2: The B flag of the 6502 processor flags should be set by BRK.  
  3: An IRQ should have occurred.  
  4: The B flag of the 6502 processor flags should not be set by an IRQ.  
  5: The B flag of the 6502 processor flags should not be set by an NMI.  
  6: Bit 5 of the 6502 processor flags should be set by PHP.  
  7: Bit 5 of the 6502 processor flags should be set by BRK.  
  8: Bit 5 of the 6502 processor flags should be set by an IRQ.  
  9: Bit 5 of the 6502 processor flags should be set by an NMI.  

### Dummy read cycles
  1: A mirror of PPU_STATUS ($2002) should be read twice by LDA $20F2, X (where X = $10).  
  2: The dummy read should not occur if a page boundary is not crossed.  
  3: The dummy read was on an incorrect address.  
  4: The STA, X instruction should have a dummy read.  
  5: The STA, X dummy read was on an incorrect address.  
  6: LDA (Indirect), Y should not have a dummy read if a page boundary is not crossed by the Y indexing.  
  7: LDA (Indirect), Y should have a dummy read if a page boundary is crossed by the Y indexing.  
  8: STA (Indirect), Y should not have a dummy read if a page boundary is not crossed by the Y indexing.  
  9: STA (Indirect), Y should have a dummy read if a page boundary is crossed by the Y indexing.  
  A: LDA (Indirect, X) should not have a dummy read.  
  B: STA (Indirect, X) should not have a dummy read.  

### Dummy write cycles
  1: PPU Open Bus should exist.  
  2: Read-modify-write instructions should write to $2006 twice.  
  3: Read-modify-write instructions with X indexing should write to $2006 twice.  

### Open Bus
  1: Reading from open bus is not all zeroes.  
  2: Reading from open bus with LDA Absolute should simply return the high byte of the operand.  
  3: Indexed addressing crossing a page boundary should not update the data bus to the new high byte value.  
  4: Moving the program counter to open bus should read instructions from the floating data bus values. Write cycles should update the data bus.  
  5: Dummy reads should update the data bus.  
  6: The upper 3 bits when reading from the controller should be open bus.  
  7: Reading from $4015 should not update the data bus.  
  8: Writing should always update the data bus, even writing to $4015.  
  9: Bit 5 of address $4015 should be open bus.  

### All NOP Instructions
  (See message printed on screen for more details)  
  1: Opcode $04 (NOP Zero Page) malfunctioned.  
  2: Opcode $0C (NOP Absolute) malfunctioned.  
  3: Opcode $14 (NOP Zero Page, X) malfunctioned.  
  4: Opcode $1A (NOP Implied) malfunctioned.  
  5: Opcode $1C (NOP Absolute, X) malfunctioned.  
  6: Opcode $34 (NOP Zero Page, X) malfunctioned.  
  7: Opcode $3A (NOP Implied) malfunctioned.  
  8: Opcode $3C (NOP Absolute, X) malfunctioned.  
  9: Opcode $44 (NOP Zero Page) malfunctioned.  
  A: Opcode $54 (NOP Zero Page, X) malfunctioned.  
  B: Opcode $5A (NOP Implied) malfunctioned.  
  C: Opcode $5C (NOP Absolute, X) malfunctioned.  
  D: Opcode $64 (NOP Zero Page) malfunctioned.  
  E: Opcode $74 (NOP Zero Page, X) malfunctioned.  
  F: Opcode $7A (NOP Implied) malfunctioned.  
  G: Opcode $7C (NOP Absolute, X) malfunctioned.  
  H: Opcode $80 (NOP Immediate) malfunctioned.  
  I: Opcode $82 (NOP Immediate) malfunctioned.  
  J: Opcode $89 (NOP Immediate) malfunctioned.  
  K: Opcode $C2 (NOP Immediate) malfunctioned.  
  L: Opcode $D4 (NOP Zero Page, X) malfunctioned.  
  M: Opcode $DA (NOP Implied) malfunctioned.  
  N: Opcode $DC (NOP Absolute, X) malfunctioned.  
  O: Opcode $E2 (NOP Immediate) malfunctioned.  
  P: Opcode $EA (NOP Implied) malfunctioned.  
  Q: Opcode $F4 (NOP Zero Page, X) malfunctioned.  
  R: Opcode $FA (NOP Implied) malfunctioned.  
  S: Opcode $FC (NOP Absolute, X) malfunctioned.  

## Page 2: Addressing Mode Wraparound

### Absolute Indexed Wraparound
  1: Absolute indexed addressing did not read from the correct address.  
  2: When indexing with X beyond address $FFFF, the instruction should read from the zero page.  
  3: When indexing with Y beyond address $FFFF, the instruction should read from the zero page.  

### Zero Page Indexed Wraparound
  1: Zero Page indexed addressing did not read from the correct address.  
  2: When indexing with X beyond address $00FF, the instruction should still read from the zero page.  
  3: When indexing with Y beyond address $00FF, the instruction should still read from the zero page.  

### Indirect Addressing Wraparound
  1: JMP (Indirect) did not move the program counter to the correct address.  
  2: The address bus should wrap around the page when reading the low and high bytes with indirect addressing.  

### Indirect Addressing, X Wraparound
  1: Indirect, X addressing did not read from the correct address.  
  2: The indirect indexing should only occur on the zero page, even if X crosses a page boundary.  
  3: The address bus should wrap around the page when reading the low and high bytes with indirect addressing.  

### Indirect Addressing, Y Wraparound
  1: Indirect, Y addressing did not read from the correct address.  
  2: The Y indexing should be able to cross a page boundary, and the high byte should be updated.  
  3: The address bus should wrap around the page when reading the low and high bytes with indirect addressing.  

### Relative Addressing Wraparound
  1: You should be able to branch from the Zero Page to page $FF.  
  2: You should be able to branch from page $FF to the Zero Page.  

## Pages 3, 4, 5, 6, 7, 8, 9, 10, and 11: Unofficial Instructions

### Unofficial Instructions: SLO, RLA, SRE, RRA, SAX, LAX, DCP, ISC, ANC, ASR, ARR, ANE, LXA, AXS, SBC, SHA, SHX, SHY, SHS, LAE
  F: The high byte corruption did not match any known behavior. (Only applicable to SHA and SHS.)  
  0: This instruction had the wrong number of operand bytes.  
  1: The target address of the instruction was not correct.  
  2: The A register was not the correct value after the test.  
  3: The X register was not the correct value after the test.  
  4: The Y register was not the correct value after the test.  
  5: The CPU status flags were not correct after the test.  
  6: The stack pointer was not the correct value after the test. (Only applicable to SHS and LAE)  
  (PAL form of error codes 7 to C: a 2A07 DMA cannot halt in the middle of an instruction, so a DMC DMA requested on the cycle before the write must change nothing. The instruction is run once without a DMA and once with that request; any difference gives the code below.)  
  7: If the RDY line goes low 2 cycles before the write cycle, the target address of the instruction was not correct. (SHA, SHX, SHY, and SHS)  
  8: If the RDY line goes low 2 cycles before the write cycle, the A register was not the correct value after the test. (SHA, SHX, SHY, and SHS)  
  9: If the RDY line goes low 2 cycles before the write cycle, the X register was not the correct value after the test. (SHA, SHX, SHY, and SHS)  
  A: If the RDY line goes low 2 cycles before the write cycle, the Y register was not the correct value after the test. (SHA, SHX, SHY, and SHS)  
  B: If the RDY line goes low 2 cycles before the write cycle, the CPU status flags were not correct after the test. (SHA, SHX, SHY, and SHS)  
  C: If the RDY line goes low 2 cycles before the write cycle, the stack pointer was not the correct value after the test.  (SHS)

## Page 12: CPU Interrupts

### Interrupt Flag Latency
  1: An IRQ should occur when a DMC sample ends, the DMC IRQ is enabled, and the CPU's I flag is clear.  
  2: The IRQ should occur 2 instructions after the CLI instruction. (The CLI instruction polls for interrupts before cycle 2.)  
  3: An IRQ should be able to occur 1 cycle after the final cycle of an SEI instruction. (The SEI instruction polls for interrupts before cycle 2.)  
  4: If an IRQ occurs 1 cycle after the final cycle of an SEI instruction, the I flag should be set in the values pushed to the stack.  
  5: An IRQ should run again after an RTI if the interrupt was not acknowledged and the I flag was not set when pushed to the stack.  
  6: The IRQ should occur 1 cycle after the final cycle of an RTI instruction. (The I flag is pulled off the stack before RTI polls for interrupts.)  
  7: The IRQ should occur 2 instructions after the PLP instruction. (The PLP instruction polls for interrupts before cycle 2.)  
  8: The IRQ occurred on the wrong CPU cycle.  
  9: Branch instructions should poll for interrupts before cycle 2.  
  A: Branch instructions should not poll for interrupts before cycle 3.  
  B: Branch instructions should poll for interrupts before cycle 4.  
  C: Error code E requires proper PPU open bus emulation to verify the behavior, and your emulator did not pass a pre-requisite PPU open bus test.  
  D: Error code E enters open bus through the PPU register mirrors: the PPU I/O latch read through a mirror, or the $2007 read buffer, did not work.  
  E: An interrupt polled successfully on the first poll of a branch, cleared, and then polled again, should still occur. (PAL form, no DMA: PLAs run in open bus, a PLP pulling $90 clears the I flag and leaves BCC on the bus at $4013; the BCC's dummy read of $4015 clears the frame interrupt. Run twice, one cycle apart; the IRQ must be taken after the branch both times, return address $3FA5.)  

### NMI Overlap BRK
  1: BRK Returned to the wrong address.  
  2: The results form three runs in order (BRK then NMI, NMI hijacks BRK, NMI then BRK), the hijack run exactly 10 passes (5 CPU cycles) long.  

### NMI Overlap IRQ
  1: What happens when the NMI runs during an IRQ?  
  2: The results form three runs in order (IRQ then NMI, NMI hijacks IRQ, NMI then IRQ), the hijack run exactly 18 passes (9 CPU cycles) long.  

## Page 13: APU Registers and DMA tests

> On a 2A07 a DMC DMA only halts on an opcode fetch and makes no extra register reads. The tests on this page keep their names; what they check on PAL is listed here.

### DMA + Open Bus
  1: An opcode fetched from open bus at $4000 should be the high byte of the address ($40, RTI) when no DMA occurs.  
  2: A DMC DMA that lands on that opcode fetch should replace the opcode with the sample byte ($00, BRK); or the DMC DMA was on the wrong cycle.  

### DMA + $2002 Read
  1: Your emulator did not pass the "SLO Absolute, X" test.  
  2: The DMC DMA was on the wrong cycle, or it read $2002 more often than a 2A07 does (there are no extra reads of $2002).  

### DMA + $2007 Read
  1: The PPU Read Buffer is not working.  
  2: The DMC DMA was on the wrong cycle, or it made extra reads of $2007 (a 2A07 makes none).  
  3: The DMA did not happen at all (the sample's only byte was not fetched).  

### DMA + $2007 Write
  1: DMA + $2007 Read did not pass.  
  2: The DMA was not delayed past the write cycle.  

### DMA + $4015 Read
  1: The APU Frame Timer Interrupt Flag was never set.  
  2: The DMC DMA was on the wrong cycle, or it made an extra read of $4015 (a 2A07 makes none).  

### DMA + $4016 Read
  1: The DMC DMA was on the wrong cycle, or it clocked the controller port (a 2A07 DMA does not).  

### DMC DMA Bus Conflicts
  1: DMA + Open Bus failed (the DMA could not be caught on an opcode fetch).  
  2: The DMA reading sample byte $FFD6 during the opcode fetch at $4000 did not read the controller (the opcode stayed $00, not $01).  
  3: The DMA reading sample byte $FFD5 did not read $4015 (the frame interrupt flag was not cleared).  
### DMC DMA + OAM DMA
  1: The cycle clock did not measure a known interval correctly (two NOPs = 4 cycles).  
  2: The overlapping DMAs did not steal the expected number of CPU cycles. 32 positions of the DMC DMA against the start and the end of the OAM DMA; values at $500-$51F, key in the source.  

### Explicit DMA Abort
  1: The cycle clock did not measure a known interval correctly.  
  2: Stopping the DMC around a DMC DMA did not steal the expected number of CPU cycles. 16 positions; values at $500-$50F, key in the source.  

### Implicit DMA Abort
  1: The cycle clock did not measure a known interval correctly.  
  2: Starting a 1-byte sample shortly before the sample buffer empties did not steal the expected number of CPU cycles. 16 positions; values at $500-$50F.  
  3: The 1-cycle (aborted) DMA should not be delayed, it just should not occur: on a 2A07, when its cycle is not an opcode fetch. Values at $520-$52F.  
  4: If the sample was set to keep looping, nothing is aborted and the reload DMA follows the load DMA. Values at $540-$54F.  

## Page 14: APU Tests

### APU Length Counter
  1: Reading from $4015 should not state that the pulse 1 channel is playing before you write to $4003.  
  2: Reading from $4015 should state that the pulse 1 channel is playing after you write to $4003.  
  3: The audio channel should automatically stop playing if you wait for the length counter to expire.  
  4: Writing $80 to $4017 should immediately clock the Length Counter.  
  5: Writing $00 to $4017 should not clock the Length Counter.  
  6: Disabling the audio channel should immediately clear the length counter to zero.  
  7: The length counter shouldn't be set when the channel is disabled.  
  8: If the channel is set to play infinitely, it shouldn't clock the length counter.  
  9: If the channel is set to play infinitely, the length counter should be left unchanged.  

### APU Length Table
  1: Your emulator did not pass APU Length Counter.  
  2: When writing %00000--- to address $4003, the pulse 1 length counter should be set to 10.  
  3: When writing %00001--- to address $4003, the pulse 1 length counter should be set to 254.  
  4: When writing %00010--- to address $4003, the pulse 1 length counter should be set to 20.  
  5: When writing %00011--- to address $4003, the pulse 1 length counter should be set to 2.  
  6: When writing %00100--- to address $4003, the pulse 1 length counter should be set to 40.  
  7: When writing %00101--- to address $4003, the pulse 1 length counter should be set to 4.  
  8: When writing %00110--- to address $4003, the pulse 1 length counter should be set to 80.  
  9: When writing %00111--- to address $4003, the pulse 1 length counter should be set to 6.  
  A: When writing %01000--- to address $4003, the pulse 1 length counter should be set to 160.  
  B: When writing %01001--- to address $4003, the pulse 1 length counter should be set to 8.  
  C: When writing %01010--- to address $4003, the pulse 1 length counter should be set to 60.  
  D: When writing %01011--- to address $4003, the pulse 1 length counter should be set to 10.  
  E: When writing %01100--- to address $4003, the pulse 1 length counter should be set to 14.  
  F: When writing %01101--- to address $4003, the pulse 1 length counter should be set to 12.  
  G: When writing %01110--- to address $4003, the pulse 1 length counter should be set to 26.  
  H: When writing %01111--- to address $4003, the pulse 1 length counter should be set to 14.  
  I: When writing %10000--- to address $4003, the pulse 1 length counter should be set to 12.  
  J: When writing %10001--- to address $4003, the pulse 1 length counter should be set to 16.  
  K: When writing %10010--- to address $4003, the pulse 1 length counter should be set to 24.  
  L: When writing %10011--- to address $4003, the pulse 1 length counter should be set to 18.  
  M: When writing %10100--- to address $4003, the pulse 1 length counter should be set to 48.  
  N: When writing %10101--- to address $4003, the pulse 1 length counter should be set to 20.  
  O: When writing %10110--- to address $4003, the pulse 1 length counter should be set to 96.  
  P: When writing %10111--- to address $4003, the pulse 1 length counter should be set to 22.  
  Q: When writing %11000--- to address $4003, the pulse 1 length counter should be set to 192.  
  R: When writing %11001--- to address $4003, the pulse 1 length counter should be set to 24.  
  S: When writing %11010--- to address $4003, the pulse 1 length counter should be set to 72.  
  T: When writing %11011--- to address $4003, the pulse 1 length counter should be set to 26.  
  U: When writing %11100--- to address $4003, the pulse 1 length counter should be set to 16.  
  V: When writing %11101--- to address $4003, the pulse 1 length counter should be set to 28.  
  W: When writing %11110--- to address $4003, the pulse 1 length counter should be set to 32.  
  X: When writing %11111--- to address $4003, the pulse 1 length counter should be set to 30.  

### Frame Counter IRQ
  1: The IRQ flag should be set when the APU Frame counter is in the 4-step mode, and the IRQ flag is enabled.  
  2: The IRQ flag should not be set when the APU frame counter is in the 4-step mode, and the IRQ flag is disabled.  
  3: The IRQ flag should not be set when the APU frame counter is in the 5-step mode, and the IRQ flag is enabled.  
  4: The IRQ flag should not be set when the APU frame counter is in the 5-step mode, and the IRQ flag is disabled.  
  5: Reading the IRQ flag should clear the IRQ flag.  
  6: The IRQ flag should be cleared when the APU transitions from a "put" cycle to a "get" cycle.  
  7: The IRQ flag should not be cleared yet when the APU transitions from a "get" cycle to a "put" cycle.  
  8: Changing the frame counter to 5-step mode after the flag was set should not clear the flag.  
  9: Disabling the IRQ flag should clear the IRQ flag.  
  A: The IRQ flag was enabled too early. (writing to $4017 on a "put" cycle.)  
  B: The IRQ flag was enabled too late. (writing to $4017 on a "put" cycle.)  
  C: The IRQ flag was enabled too early. (writing to $4017 on a "get" cycle.)  
  D: The IRQ flag was enabled too late. (writing to $4017 on a "get" cycle.)  
  E: Reading $4015 on the last cycle before the IRQ flag is set should not clear the IRQ flag. (it gets set on the following 2 CPU cycles)  
  F: Reading $4015 on the same cycle the IRQ flag is set should not clear the IRQ flag. (it gets set again on the following CPU cycle)  
  G: Reading $4015 1 cycle later than the previous test should not clear the IRQ flag. (it gets set again on this CPU cycle)  
  H: Reading $4015 1 cycle later than the previous test should clear the IRQ flag.  
  I: The Frame Counter Interrupt flag should not have been set 29827 cycles after resetting the frame counter.  
  J: The Frame Counter Interrupt flag should have been set 29828 cycles after resetting the frame counter, even if suppressing Frame Counter Interrupts.  
  K: The Frame Counter Interrupt flag should have been set 29829 cycles after resetting the frame counter, even if suppressing Frame Counter Interrupts.  
  L: The Frame Counter Interrupt flag should not have been set 29830 cycles after resetting the frame counter if suppressing Frame Counter Interrupts.  
  M: Despite the Frame Counter Interrupt flag being set for those 2 CPU cycles, if suppressing Frame Counter Interrupts, an IRQ should not occur.  
  N: The IRQ Occurs on the wrong CPU cycle.  
  O: The IRQ Occurs on the wrong CPU cycle.  

### Frame Counter 4-step
  1: The first clock of the length counters was early.  
  2: The first clock of the length counters was late.  
  3: The second clock of the length counters was early.  
  4: The second clock of the length counters was late.  
  5: The third clock of the length counters was early.  
  6: The third clock of the length counters was late.  

### Frame Counter 5-step
  1: The first clock of the length counters was early.  
  2: The first clock of the length counters was late.  
  3: The second clock of the length counters was early.  
  4: The second clock of the length counters was late.  
  5: The third clock of the length counters was early.  
  6: The third clock of the length counters was late.  

### Delta Modulation Channel
  1: Reading address $4015 should set bit 4 when the DMC is playing and clear bit 4 when the sample ends.  
  2: Restarting the DMC should re-load the sample length.  
  3: Writing $10 to $4015 should start playing a new sample if the previous one ended.  
  4: Writing $10 to $4015 while a sample is currently playing shouldn't affect anything.  
  5: Writing $00 to $4015 should immediately stop the sample.  
  6: Writing to $4013 shouldn't change the sample length of the currently playing sample.  
  7: The DMC IRQ flag should not be set when disabled.  
  8: The DMC IRQ flag should be set when enabled, and a sample ends.  
  9: Reading $4015 should not clear the IRQ flag.  
  A: Writing to $4015 should clear the IRQ flag.  
  B: Disabling the IRQ flag should clear the IRQ flag.  
  C: Looping samples should loop.  
  D: Looping samples should not set the IRQ flag when they loop.  
  E: Clearing the looping flag and then setting it again should keep the sample looping.  
  F: Clearing the looping flag should not immediately end the sample. The sample should then play for its remaining bytes.  
  G: A looping sample should reload the sample length from $4013 every time the sample loops.  
  H: Writing $00 to $4013 should result in the following sample being 1 byte long.  
  I: There should be a one-byte buffer that's filled immediately if empty.  
  J: The DMA occurred on the wrong CPU cycle.  
  K: The sample address should overflow to $8000 instead of $0000. (PAL form: a 225-byte sample from $FFC0 ends on $80A0, which holds $00; that byte is fetched as an opcode.)  
  L: Enabling the DMC 2 cycles before the sample buffer empties should give a DMA timed from the $4015 write (first halt attempt on the 3rd cycle after a write on a put cycle), not from the buffer emptying.  
  M: Enabling the DMC 1 cycle before the sample buffer empties: first halt attempt on the 4th cycle after the write (a write on a get cycle).  
  N: Enabling the DMC on the cycle the sample buffer empties: first halt attempt on the 3rd cycle after the write.  

### APU Register Activation
  1: A series of prerequisite tests failed. CPU and PPU open bus, PPU Read Buffer, the DMA sync, and DMA + $2007 Read.  
  2: There were unexpected extra bits when reading from a controller port that should not have been set.  
  3: Reading from $4015 should clear the APU Frame Counter Interrupt flag.  
  4: The OAM DMA should not be able to read from the APU registers if $40 is written to $4016, and the CPU Address Bus is not in the range of $4000 to $401F.  
  5: Something went wrong during the open bus execution (PAL form: STA ($50),Y executed at $3FFE writes $4014, so the OAM DMA halts the CPU on the opcode fetch at $4000; no DMC DMA is involved).  
  6: The OAM DMA should be able to read from the APU registers (and mirrors of them) if $40 is written to $4016, and the CPU Address Bus is in the range of $4000 to $401F.  
  7: Bus conflicts with the APU registers were not properly emulated.  

### Controller Strobing
  1: A value of $02 written to $4016 should not strobe the controllers.  
  2: Any value with bit 0 set written to $4016 should strobe the controllers.  
  3: Controllers should be strobed when the CPU transitions from a "get" cycle to a "put" cycle.  
  4: Controllers should not be strobed when the CPU transitions from a "put" cycle to a "get" cycle.  

### Controller Clocking
  1: Reading $4016 more than 8 times should always result in bit 0 being set to 1.  
  2: Reading from a controller port while it is still strobed shouldn't affect the contents of the shift register, as it should be constantly loaded with the currently held buttons.  
  3: Your emulator did not pass the SLO Absolute, X test.  
  4: (NES / AV Famicom only) Double-reading address $4016 should only clock the controller once.  
  5: (NES / AV Famicom only) This double-read should be the same value for both reads.  
  6: (PAL) A DMC DMA requested during a read of $4016 must not give the controller an extra clock: the read clocks it once.  
  7: (PAL) The same with a DMA address that matches $4016 in its low 5 bits: still one clock.  

## Page 15: CPU Behavior 2

### Instruction Timing
  (PAL form: every length is measured with a cycle clock built on the frame IRQ; no open bus is used.)  
  1: The DMA sync could not be done.  
  2: The cycle clock did not measure two NOPs as 4 cycles.  
  3: The immediate addressing mode takes 2 cycles.  
  4: Zero Page, non-Read-Modify-Write: 3 cycles.  
  5: Zero Page, Read-Modify-Write: 5 cycles.  
  6: Zero Page indexed, non-Read-Modify-Write: 4 cycles.  
  7: Zero Page indexed, Read-Modify-Write: 6 cycles.  
  8: Absolute, non-Read-Modify-Write: 4 cycles.  
  9: Absolute, Read-Modify-Write: 6 cycles.  
  A: Absolute indexed STA always takes 5 cycles.  
  B: Absolute indexed takes an extra cycle if a page boundary is crossed.  
  C: Absolute indexed Read-Modify-Write always takes 7 cycles.  
  D: (Indirect, X) always takes 6 cycles.  
  E: (Indirect), Y takes an extra cycle if a page boundary is crossed.  
  F: Implied instructions take 2 cycles.  
  G: PHP takes 3 cycles.  
  H: PHA takes 3 cycles.  
  I: PLP takes 4 cycles.  
  J: PLA takes 4 cycles.  
  K: JMP takes 3 cycles.  
  L: JSR takes 6 cycles.  
  M: RTS takes 6 cycles.  
  N: RTI takes 6 cycles.  
  O: BRK takes 7 cycles.  
  P: JMP (indirect) takes 5 cycles.  

### Implied Dummy Reads
  0: Your emulator did not pass the "SLO Absolute, X" test.  
  1: There were unexpected extra bits when reading from a controller port that should not have been set.  
  2: Your emulator did not implement the frame counter interrupt flag properly.  
  3: The PPU read buffer did not work. (PAL form: this test uses no DMC DMA; each opcode is put on the bus by PLAs running in open bus, entered through $3FFE/$3FFF.)  
  4: Your emulator did not correctly emulate open bus behavior. (Or JSR reads its second operand before pushing the return address: PAL form, a JSR placed at $4010 by PLAs must land on $1220.)  
  5: ASL A should perform a dummy read on cycle 2. (The PC was incremented after reading the opcode in the previous cycle, so these dummy reads should occur from the new location of the PC.)  
  6: CLC should perform a dummy read on cycle 2.  
  7: LSR A should perform a dummy read on cycle 2.  
  8: CLI should perform a dummy read on cycle 2.  
  9: DEY should perform a dummy read on cycle 2.  
  A: TXA should perform a dummy read on cycle 2.  
  B: TYA should perform a dummy read on cycle 2.  
  C: TXS should perform a dummy read on cycle 2.  
  D: INY should perform a dummy read on cycle 2.  
  E: DEX should perform a dummy read on cycle 2.  
  F: CLD should perform a dummy read on cycle 2.  
  G: ROL A should perform a dummy read on cycle 2.  
  H: SEC should perform a dummy read on cycle 2.  
  I: ROR A should perform a dummy read on cycle 2.  
  J: SEI should perform a dummy read on cycle 2.  
  K: TAY should perform a dummy read on cycle 2.  
  L: TAX should perform a dummy read on cycle 2.  
  M: CLV should perform a dummy read on cycle 2.  
  N: TSX should perform a dummy read on cycle 2.  
  O: INX should perform a dummy read on cycle 2.  
  P: SED should perform a dummy read on cycle 2.  
  Q: NOP should perform a dummy read on cycle 2.  
  R: PHP should perform a dummy read on cycle 2.  
  S: PHA should perform a dummy read on cycle 2.  
  T: PLP should perform a dummy read on cycle 2.  
  U: PLA should perform a dummy read on cycle 2.  
  V: BRK should perform a dummy read on cycle 2.  
  W: RTI should perform a dummy read on cycle 2.  
  X: RTS should perform a dummy read on cycle 2.  
  Y: RTS should perform a dummy read on cycle 6. (PAL form: the RTS returns to $2008, so the dummy read is a read of $2007.)  

### Branch Dummy Reads
  1: Your emulator does not accurately emulate RAM Mirroring.  
  2: Your emulator does not accurately emulate the PPU Open Bus.  
  3: Your emulator does not accurately emulate reads from address $2004.  
  4: The third CPU cycle of branch instructions should dummy read from the byte following the operand.  
  5: The fourth CPU cycle of branch instructions (if the branch crosses a page boundary) should dummy read from the location of the PC before correcting the high byte.  

### JSR Edge Cases
  1: Your emulator pushed the wrong value for the return address.  
  2: JSR should push the return address to the stack between reading the first and second operand.  
  3: Your emulator has incorrect open bus emulation.  
  4: JSR should leave the value of the second operand on the data bus.  

### Internal Data Bus
  1: Reading from open bus should work correctly when crossing a page boundary.  
  2: The external data bus (a DMC DMA's byte) cannot change the internal data bus.  
  3: Reads from $4015 only update the internal data bus and cannot affect the external data bus.  

### DMA Landing on Write
  1: Open bus should not always read 00.  
  2: The DMC DMA should update the data bus when it lands on an opcode fetched from open bus.  
  3: (2A07) A DMA requested on a write cycle waits for the next opcode fetch.  
  4: (2A07) ...also when requested on the second of two write cycles.  
  5: (2A07) ...and on a read that is not an opcode fetch; not when requested on an opcode fetch.  
  6: (2A07) A load DMA's first halt attempt is in the 2nd APU cycle after the $4015 write.  
  7: (2A07) ...which is the 3rd cycle after a write on a put cycle.  
  8: Load DMAs also cannot land on write cycles.  
  9: (2A07) ...and a load DMA lands on the first opcode fetch after its first attempt.  

### DMC Reload Timing
  1: Writing to $4010 as the DMC timer resets should cause the timer to reload using the new value. (PAL form: two probes on fixed cycles; the key is derived, not measured.)  

### DMC Playback Rate
  1: DMA + Open Bus did not pass.  
  2: Sample rate %0000 should take 3184 CPU cycles before the DMC DMA occurs.  
  3: Sample rate %0001 should take 2832 CPU cycles before the DMC DMA occurs.  
  4: Sample rate %0010 should take 2528 CPU cycles before the DMC DMA occurs.  
  5: Sample rate %0011 should take 2384 CPU cycles before the DMC DMA occurs.  
  6: Sample rate %0100 should take 2208 CPU cycles before the DMC DMA occurs.  
  7: Sample rate %0101 should take 1888 CPU cycles before the DMC DMA occurs.  
  8: Sample rate %0110 should take 1680 CPU cycles before the DMC DMA occurs.  
  9: Sample rate %0111 should take 1584 CPU cycles before the DMC DMA occurs.  
  A: Sample rate %1000 should take 1408 CPU cycles before the DMC DMA occurs.  
  B: Sample rate %1001 should take 1184 CPU cycles before the DMC DMA occurs.  
  C: Sample rate %1010 should take 1056 CPU cycles before the DMC DMA occurs.  
  D: Sample rate %1011 should take 944 CPU cycles before the DMC DMA occurs.  
  E: Sample rate %1100 should take 784 CPU cycles before the DMC DMA occurs.  
  F: Sample rate %1101 should take 624 CPU cycles before the DMC DMA occurs.  
  G: Sample rate %1110 should take 528 CPU cycles before the DMC DMA occurs.  
  H: Sample rate %1111 should take 400 CPU cycles before the DMC DMA occurs.  

## Page 16: Power On State

> **Soft reset:** A warm reset now clears test RAM, disables NMI/rendering, stops the APU/DMC, resets the OAM address and reinitializes OAM, palette, and nametable state before returning to the menu. The power-on snapshot tests are skipped on a warm reset because a reset cannot recreate uninitialized power-on RAM/VRAM.

### DRAW PPU Reset Flag
  This test attempts to write to the ppu registers before the end of the first VBlank.  
  "No Reset Flag Detected!" will be printed if the write was successful.  
  "Reset Flag Detected!" will be printed if the write was unsuccessful.  

### DRAW CPU RAM
  This test prints uninitialized RAM values from address $300 through $31F. Some known examples include the following:  
<pre>
F0 F0 0F 0F F0 F0 0F 0F
F0 F0 0F 0F F0 F0 0F 0F
0F 0F F0 F0 0F 0F F0 F0
0F 0F F0 F0 0F 0F F0 F0
</pre>
or  
<pre>
00 00 00 00 FF FF FF FF
00 00 00 00 FF FF FF FF
00 00 00 00 FF FF FF FF
00 00 00 00 FF FF FF FF
</pre>
  Other known patterns include all `00`s or all `FF`s.  

### DRAW CPU Registers
  This test prints uninitialized register contents recorded at power on.  
  Note that there have been consoles known to have noise in some of these bits, and there is no "canonical" power on state for these.  
<pre>
              A 00
              X 00
              Y 00
  Stack Pointer FD
Processor Flags 04
</pre>

### DRAW PPU RAM
  This test prints uninitialized RAM values from VRAM address $2C00 through $2C1F. Some known examples include the following:  
<pre>
F0 F0 0F 0F F0 F0 0F 0F
F0 F0 0F 0F F0 F0 0F 0F
0F 0F F0 F0 0F 0F F0 F0
0F 0F F0 F0 0F 0F F0 F0
</pre>
or  
<pre>
00 00 00 00 FF FF FF FF
00 00 00 00 FF FF FF FF
00 00 00 00 FF FF FF FF
00 00 00 00 FF FF FF FF
</pre>
  Other known patterns include all `00`s or all `FF`s.  

### DRAW Palette RAM
  This test prints uninitialized RAM values from Palette RAM, $3F00 through $3F1F.  
  Note that pre-G PPUs are unable to read palette RAM.  
  Additionally, every console tested appears to have a unique and consistent power on state for palette RAM. My console has the following:  
<pre>
00 00 28 00 00 08 00 00
00 01 01 20 00 08 00 02
00 00 00 00 00 02 21 00
00 00 00 00 00 10 00 00
</pre>
  I've ran my test on other consoles, and here are a few other results:  
<pre>
10 00 00 00 00 00 00 00
00 20 00 00 00 00 00 00
10 20 00 10 00 10 00 00
00 10 10 20 00 10 20 00
</pre>
  While the two result above would suggest it's mostly all zeroes with a few bit flips, I have also seen the following:  
<pre>
20 24 0A 25 34 11 0F 02
00 26 04 25 08 1D 25 12
20 07 02 00 34 22 00 00
00 08 00 00 08 02 03 02
</pre>

## Page 17: PPU Behavior  

### CHR ROM is not Writable
  1: Writes to the PPU Address space from the range $0000 through $1FFF should not overwrite the CHR data if the cartridge has CHR ROM instead of CHR RAM.  

### PPU Register Mirroring
  1: PPU registers should be mirrored through $3FFF.  

### PPU Register Open Bus
  1: Reading from a write-only register PPU should return the most recently written value to the PPU IO bus.  
  2: All PPU Registers should update the PPU IO bus when written.  
  3: Bits 0 through 4 when reading from address $2002 should read the PPU IO bus.  
  4: Reads from $2002 should update the upper 3 bits of the PPU IO bus.  
  5: The PPU IO bus value should decay before 1 second passes.  

### PPU Read Buffer
  1: Reading from the PPU register at $2007 is not working at all in this emulator.  
  2: Reading address $2007 should increment the "v" register.  
  3: There should be a 1-byte buffer when reading from $2007.  
  4: Reading from CHR ROM should use the buffer.  
  5: Writing to $2006 does not modify the buffer value.  
  6: Reading from Palette RAM should NOT use the buffer.  
  7: The value on the nametable at $2F00 through $2FFF should be put in the buffer when reading from palette RAM at $3F00 through $3FFF.  

### Palette RAM Quirks
  1: This emulator failed the PPU Read Buffer test.  
  2: Palette RAM should be mirrored through $3FFF.  
  3: The backdrop colors for palettes 1, 2, and 3 should not be mirrors of the backdrop color of palette 0.  
  4: The backdrop colors for sprites should be mirrors of the backdrop colors for backgrounds.  
  5: The values read from Palette RAM should only be 6-bit, with the upper 2 bits being PPU open bus.  
  6: With "Greyscale Mode" enabled, the lower four bits of the value read should all be zero.  
  7: With "Greyscale Mode" enabled, the lower four bits of the value written should be unaffected.

## Page 18: PPU VBlank Timing

### VBlank Beginning
  1: The 8 samples (1.6 dots apart, the read pair of the 2C02 test) did not go 02 ... [one 00] ... 01. Press Select: $50-$57.  
### VBlank End
  1: The 8 samples (1.6 dots apart) did not go 1 ... 0 with a single change at the end of VBlank. Press Select: $50-$57.  
### NMI Control
  1: The NMI should not occur when disabled.  
  2: The NMI should occur at VBlank when enabled.  
  3: The NMI should occur when enabled during VBlank, if the VBlank flag is enabled.  
  4: The NMI should not occur when enabled during VBlank, if the VBlank flag is disabled.  
  5: The NMI should not occur a second time if writing $80 to $2000 when the NMI flag is already enabled.  
  6: The NMI should not occur a second time if writing $80 to $2000 when the NMI flag is already enabled, and the NMI flag was enabled going into VBlank.  
  7: The NMI should occur an additional time if you disable and then re-enable the NMI.  
  8: The NMI is polled before the write cycle of STA, resulting in a gap between enabling the NMI and the NMI occurring. (See Interrupt flag latency.)  
  9: The NMI is polled between the write cycles of INC, resulting the NMI occurring immediately after the INC. (See Interrupt flag latency.)
  PAL: the 2C02 checks with PAL frame (33248 cycles) and VBlank (7462 cycles) waits.  
### NMI Timing
  1: The NMI did not land in the INY chain, or a value did not last 4 samples (2 CPU cycles at 1.6 dots per sample). Press Select: $50-$59.  
### NMI Suppression
  1: The samples did not go 02 ... [00] ... [01] ... 03 (00 at most once, 01 at most twice). Press Select: $50-$59.  
### NMI at VBlank End
  1: Enabling the NMI near the end of VBlank did not change from "NMI" to "no NMI" once, or the two ways of enabling it disagreed. Press Select: $50-$57, $60-$67.  
### NMI Disabled at VBlank
  1: Disabling the NMI near the start of VBlank did not change from "no NMI" to "NMI" once. Press Select: $50-$57.  
## Page 19: Sprite Evaluation

### Sprite 0 Hit Behavior
  1: A Sprite zero hit did not occur.  
  2: Sprite zero hits should not happen if background rendering is disabled.  
  3: Sprite zero hits should not happen if sprite rendering is disabled.  
  4: Sprite zero hits should not happen if both sprites and background Rendering are disabled.  
  5: Sprite zero hits should not happen if sprite zero is completely transparent.  
  6: Sprite zero hits should be able to happen at X=254.  
  7: Sprite zero hits should not be able to happen at X=255.  
  8: Sprite zero hits should not happen if sprite zero is at X=0, and the PPU's 8 pixel mask is enabled (show BG, no sprite).  
  9: Sprite zero hits should not happen if sprite zero is at X=0, and the PPU's 8 pixel mask is enabled (show sprite, no BG).  
  A: Despite the 8 pixel mask, if the sprite has visible pixels beyond the mask the sprite zero hit should occur.  
  B: Sprite zero hits should be able to happen at Y=238.  
  C: Sprite zero hits should not be able to happen at Y>=239  
  D: Your sprites are being rendered one scanline higher than they should be, or your sprite zero hit detection isn't actually checking for "solid pixels" overlapping.  
  E: The sprite zero hit flag was set too early.
  PAL: test E's two reads are 2 CPU cycles before and after the hit at X=254 of scanline 1.  
### $2002 Flag Timing
  1: Reading $2002 across the dot where the flags clear did not give $E0 ... $80 (once or twice) ... $00. The 2A07's M2 duty cycle is 19/32, so the sprite flags are read 1.9 dots after the VBlank flag is latched. Press Select: $50-$57.  
### Suddenly Resize Sprite
  1: Sprite Zero Hits should be working.  
  2: Writing to $2000 to enable 16 pixel tall sprites at the beginning of HBlank should properly allow an otherwise out-of-range 8 pixel tall sprite to extend into the current scanline.  
  3: This does the same thing as error code 2, but writes to $2000 after sprite zero would be determined out-of-range. The data should not exist in the shift registers despite it now being in range.  
  4: Writing to $2000 to disable 16 pixel tall sprites at the beginning of HBlank should properly prevent an otherwise in-range 16 pixel tall sprite from extending into the current scanline.  
  5: This does the same thing as error code 4, but writes to $2000 after sprite zero would be prepared in the sprite shift registers. The data should still exist in the shift registers despite it now being out of range.
  PAL: every write is placed on the 2C02 version's dot at 3.2 dots per CPU cycle (within about 2 dots).  
### Misaligned OAM DMA
  1: Sprite Zero Hits should be working.  
  2: If an OAM DMA occurs while the OAM Address is non-zero, then the OAM DMA should start writing at a non-zero address of OAM.  

### Misaligned OAM Behavior
  1: Misaligned OAM should be able to trigger a sprite zero hit.  
  2: Misaligned OAM should stay misaligned until an object's Y position is out of the range of this scanline, at which point the OAM address is incremented by 4 and bitwise ANDed with $FC.  
  3: If Secondary OAM is full when the Y position is out of range, instead of incrementing the OAM Address by 4 and bitwise ANDing with $FC, you should instead only increment the OAM address by 5.  
  4: Misaligned OAM should realign if an object's X position is out of the range of this scanline, at which point the OAM address is incremented by 1 and bitwise ANDed with $FC.  
  5: A combination of tests 3 and 4 but occurring on the same scanline.  
  6: The same as test 4, but the initial OAM address was $02 instead of $01. If you see this error code, you might have a false positive on test 4.  
  7: The same as test 5, but the initial OAM address was $03 instead of $01. If you see this error code, you might have a false positive on test 5.
  PAL: OAMADDR is set to 0 before the OAM DMA, because the 2C07's forced refresh (scanlines 265-310) moves it every frame.  
### Sprite Overflow Behavior
  1: Evaluating 9 sprites in a single scanline should set the Sprite Overflow Flag.  
  2: The Sprite Overflow Flag should not be the same thing as the CPU's Overflow flag.  
  3: Evaluating only 8 sprites in a single scanline should not set the Sprite Overflow Flag.  
  4: Sprite evaluation should occur even if only the background is being rendered. This should also set the Sprite Overflow Flag.
  PAL: the "until rendering reaches the sprites" waits are 7646 cycles (PAL VBlank is 7459 cycles).  
### Arbitrary Sprite Zero
  1: Sprite 0 should trigger a sprite zero hit. No other sprite should.  
  2: The first processed sprite of a scanline should be treated as "sprite zero".  
  3: Misaligned OAM should be able to trigger a sprite zero hit.
  PAL: the $2003 writes land at the end of the pre-render line (scanline 311), as the 2C02 version's do on 261.  
### OAM Corruption
  1: This emulator failed to sync the CPU to VBlank during a test that ran when the ROM boots.  
  2: OAM Corruption should "corrupt" a row in OAM by copying the 8 values from row 0 to another row.  
  3: This corruption should not occur immediately after disabling rendering.  
  4: This corruption should not occur immediately after re-enabling rendering.
  PAL (pending hardware: PAL PPUs were never tested for this): the key is the 2C02's. On a failure, press Select: $5FF = 8 x the corrupted row ($00 = no row corrupted).  
## Page 20: PPU Misc.

### t Register Quirks
  1: Sprite Zero Hits should be working.  
  2: Writing to $2006 should overwrite some of the bits set up by writing to $2005.  
  3: Writes to $2005 and $2006 should use the same "write latch". Tested by performing a single write to $2006 and then writing to $2005.  
  4: Writes to $2005 and $2006 should use the same "write latch". Tested by performing a single write to $2005 and then writing to $2006.  
  5: Writing to $2000 between writes to $2006 should still properly set the "nametable select" bits of the t register.  

### Address $2004 Behavior
  1: Writes to $2004 should update OAM and increment the OAM address by 1.  
  2: Reads from $2004 should give you a value in OAM, but do not increment the OAM address.  
  3: Reads from the attribute bytes should be missing bits 2 through 4.  
  4: Reads from $2004 during PPU cycles 1 to 64 of a visible scanline (with rendering enabled) should always read $FF.  
  5: Reads from $2004 during PPU cycles 1 to 64 of a visible scanline (with rendering disabled) should do a regular read of $2004.  
  6: Writing to $2004 on a visible scanline should increment the OAM address by 4.  
  7: Writing to $2004 on a visible scanline shouldn't write to OAM.  
  8: Reads from $2004 during PPU cycles 65 to 256 of a visible scanline (with rendering enabled) should read from the current OAM address.  
  9: Reads from $2004 during the fetches of the empty sprite slots (PPU cycles 265 to 320 of a visible scanline, rendering enabled) should read $FF.  
  A: Writing to $2004 on a visible scanline should increment the OAM address by 4, and then bitwise AND the OAM address with $FC.  

### INC $4014
  1: The DMC DMA should update the data bus.  
  2: The OAM DMA should use the value of the second write to $4014 as the page number. Requires precise DMC DMA timing, results are tested via a sprite zero hit.  
  3: Only a single OAM DMA should occur despite two writes to $4014.
  PAL: a 2A07 DMA cannot put $05 on the bus, so INC $3FF5,X (X=$1F) puts the OAM byte $05 there with a dummy read of $3F14 (a $2004 mirror).  
### Rendering Flag Behavior
  1: Background shift registers should not be initialized or clocked when rendering is entirely disabled.  
  2: Background shift registers should be initialized and clocked when only rendering sprites.  
  3: Sprite Evaluation should still occur when only rendering the background.
  PAL: the writes land on the 2C02 version's dots (scanline 0 dot 321, scanline 1 dot 121).  
### $2007 Read w/ Rendering
  1: Sprite Zero Hits should be working.  
  2: Reading from $2007 while rendering is enabled should result in a vertical increment of v.  

### $2004 Stress Test
  1: The pre-test (VBlank sync) failed.  
  2: With OAM set to $FF, $FE ... $00, the $2004 reads (220 samples, 1.6 dots apart) did not match the 2C02 key on the dots they landed on.  
  3: The same with the second OAM layout and the second key.  
### $2007 Stress Test
  1: The pre-test (VBlank sync) failed.  
  2: The read buffer values (214 samples, 1.6 dots apart) did not match the 2C02 key on the odd dots they landed on (dot % 8 = 7 excluded: at 3.2 dots per cycle the read straddles the next fetch there).  
## Page 21: Advanced Background Evaluation

### Attributes as Tiles
  1: Moving the PPU t register to an attribute table should render the attribute bytes as tile data in scanlines 0 to 15. Results are tested via a sprite zero hit.  
  2: With the t register pointing to an attribute table, scanlines 16 to 239 should be from the same nametable as the attributes.  

### Stale BG Shift Registers
  1: Sprite Zero Hits should be working.  
  2: Sprite Zero hits shouldn't occur if sprite zero isn't overlapping a solid pixel.  
  3: The background shift registers should not be clocked during H-Blank or F-Blank. After re-enabling rendering, a sprite zero hit should be able to occur entirely on stale background shift register data.  
  4: The sprite shifters should treat all sprites X positions as 0 if rendering has already been disabled and remains that way during dot 339.  

### BG Serial In
  1: Sprite zero hits should not occur when the nametable is entirely blank.  
  2: Background shift registers should bring in a 1 into bit 0 when shifted. These can be drawn on screen with carefully timed writes to $2001 to enable/disable rendering to skip reloading the shift registers.
  PAL: rendering is off for 19 dots instead of 18 (no CPU instruction pair gives 18 dots at 3.2 dots per cycle), so sprite zero is at X=$93 instead of $92.  
### ALE + Read
  1: Sprite Zero Hits should be working.  
  2: A well timed read from $2007 should be able to affect the PPU Address Bus during the background read cadence, reading a bit plane from an unintended address.
  PAL: the read is tried 6 times, 1.6 dots apart. Every way the ROM can move the read is a multiple of 1.6 dots, and 5 x 1.6 = 8 (one fetch group), so whether a try's address latch can fall on dot 227 depends only on the console's CPU/PPU alignment at power-on: by the PPUDATA read timing, 2 of the 5 PAL alignments can, 3 cannot.  
  Error 2 means no hit in 6 tries: power-cycle and run the test again. If no power-on in about 10 ever passes, the 2C07 does not have this effect. Press Select: $5F = the try that hit (0-5), or 6 if none did.  

### Hybrid Addresses
  1: Sprite Zero Hits should be working.  
  2: A well timed to $2006 should be able to affect the PPU Address Bus during the background read cadence, performing a nametable fetch from an unintended address.  

## Page 22: Advanced Sprite Evaluation

### Sprites On Scanline 0
  1: A sprite at Y=0 was drawn on scanline 0.  
  2: A sprite was not drawn on scanline 0 under the pre-render-line conditions (PAL: the in-range check uses 311 & 255 = 55, so the sprite is at Y=50).  
  3: The two frames differed, or a sprite zero hit occurred at X=0 (the 2C07 never skips a dot, so it must behave like the 2C02 test's RGB PPU).  
### Stale Sprite Shift Registers
  1: Sprite Zero Hits should be working.  
  2: Sprite counters should continue clocking during F-Blank.  
  3: The sprite shift registers should not be clocked during F-Blank or H-Blank.  
  4: Sprite Zero hits shouldn't occur at X=$FF.  
  5: Sprites should be drawn as soon as rendering is enabled if the shifters were reset during H-Blank, but dot 339 was during F-Blank.  
  6: F-Blank should prevent the shift registers and counters from being reloaded during H-Blank, allowing the sprite to be drawn as soon as rendering is re-enabled.
  PAL: the writes land on the 2C02 version's dots (within about 1 dot).  
### Frozen OAM2 Increment
  1: Sprite Zero Hits should be working.  
  2: If the "OAM2 Overflowed Flag" is raised, the OAM2 Address cannot be incremented. Precise toggles of rendering can keep this flag raised during Sprite Fetch.  
  3: If the OAM2 address overflows for any reason, including the end of sprite fetch where the address is incremented on dot 321, the "OAM2 Overflowed Flag" is raised.  
  4: If the OAM2 Overflowed flag is not set, then Sprite Fetch should work as normal.  
  
### Misaligned OAM2 Address
  1: Sprite Zero Hits should be working.  
  2: Reading from Address $2004 between dots 321 and 340 of a scanline should (under normal conditions) read from index 0 of OAM2.  
  3: If rendering is disabled temporarily during sprite fetch and quickly re-enabled, then the OAM2 Address did not increment while rendering was disabled, so reading from address $2004 between dots 321 and 340 of this scanline will now read from a different OAM2 address.
  PAL: test 4 needs rendering off for 18 dots; at 3.2 dots per cycle this uses 19.2, with the writes placed on dots 267 and 286.  
# Hardware validation

Nothing in this ROM has been run on a PAL NES. A hardware run should record the result table of the run-all mode and, for any failure, the error code and the debug menu (Select) bytes. The tests below are the ones whose expected values are **derived, not measured**; they are the ones a hardware run is for. Everything else is the original AccuracyCoin test with PAL timing constants.

Dot-exact tests depend on the console's CPU/PPU alignment, which is set at power-on: run the ROM after several separate power-ons and record each result.

| Test | What to record | What the expectation rests on |
|---|---|---|
| DMA sync (runs at boot and inside most tests below) | whether any DMA test reports a sync failure | the DMC DMA halting on the first opcode fetch at or after its request |
| Instruction Timing | pass/fail and the error code | the frame-IRQ cycle clock; BRK's key includes the clock's own handler path |
| Interrupt Flag Latency, A and B | pass/fail | two frame-IRQ sweeps compared with each other |
| Interrupt Flag Latency, E | pass/fail; on a failure, `$54` (which of the two passes) and `$52/$53` (return address) | branch polling rules; the `$4015` read clearing the flag only on a put cycle |
| DMA + Open Bus | pass/fail | the probe itself |
| Internal Data Bus, 2 | pass/fail | the probe |
| DMA Landing on Write, 3-7 and 9 | pass/fail and error code | fetch-only halting; the load DMA's 3rd/4th-cycle rule; the cycle parity after an OAM DMA |
| DMC Reload Timing | pass/fail | a re-encoded key (1 = probe hit) |
| DMC Playback Rate | pass/fail and error code | the 16 PAL periods; the first DMA stealing 4 cycles |
| Delta Modulation Channel, K | pass/fail | every reload DMA landing on the loop's NOP for 225 bytes |
| Delta Modulation Channel, L-N | pass/fail and error code | the load-DMA rule; the buffer emptying on a put cycle |
| APU Register Activation, 5-7 | pass/fail, the 256 bytes at `$500-$5FF`, the success code | the published 2A03 tables, assumed unchanged on the 2A07; the 2C07's forced OAM refresh being limited to scanlines 265-310 |
| Implied Dummy Reads | pass/fail and error code. Error 5 with every later opcode untested means the cycle parity after the OAM DMA is the other one, not that the dummy reads are missing | 6502 behavior common to both CPUs; the parity after an OAM DMA |
| DMC DMA + OAM DMA | the 32 bytes at `$500-$51F` | the published costs of a DMC DMA during an OAM DMA (2, 1, 3 cycles) plus fetch-only halting outside it |
| Explicit DMA Abort | the 16 bytes at `$500-$50F` | the 2A03's abort bug assumed present; an aborted DMA taking its one cycle only on an opcode fetch; **positions 5 and 6 (a stop written while the halt is still waiting for an opcode fetch) are documented nowhere and derived from the general rule** |
| Implicit DMA Abort | the 48 bytes at `$500-$50F`, `$520-$52F`, `$540-$54F` and the success code | the same bug; the load DMA delayed to an opcode fetch after a write on a get cycle |
| Address $2004 Behavior, 8 and 9 | pass/fail and the success code | the VBlank sync's dot phase: 9 must read on dots 265-320 (it reads on dot 291, a 27-dot margin either way) |
| SHA / SHS / SHX / SHY | the success code (which SHA/SHS behavior the 2A07 shows); error 7 would mean a DMA changed the value written | only behavior 1 has been observed so far; error codes 7-C compare two runs of the same instruction, so they need no per-behavior key |
| Controller Clocking, DMA + $4016 Read | pass/fail | console and controller dependent; PAL consoles have diodes on the controller lines |
| VBlank Beginning, VBlank End, NMI Timing, NMI Suppression, NMI at VBlank End, NMI Disabled at VBlank | pass/fail; on a failure the samples at `$50-$59` (and `$60-$67` for NMI at VBlank End) | the 2C02 flag and NMI rules; the samples are 1.6 dots apart, so the keys check the order of the results |
| $2002 Flag Timing | pass/fail; `$50-$57` | the 2A07's M2 duty cycle (19/32): the sprite flags are read 1.9 dots after the VBlank flag is latched |
| Sprite 0 Hit Behavior, E | pass/fail | the reads 2 CPU cycles before and after the hit |
| Sprites On Scanline 0 | pass/fail; `$500-$503` | the pre-render line's in-range check using 311 & 255 = 55 (sprite at Y=50); no skipped dot on the 2C07 |
| BG Serial In | pass/fail | 19 dots of rendering off (no instruction pair gives 18), sprite zero at X=$93 |
| Frozen OAM2 Increment, Misaligned OAM2 Address, Stale Sprite Shift Registers, Suddenly Resize Sprite, Rendering Flag Behavior | pass/fail and error code | writes placed on the 2C02 versions' dots; the console's CPU/PPU alignment is not known |
| OAM Corruption | pass/fail; on a failure `$5FF` (8 x the corrupted row, `$00` = none) | the corruption has never been tested on a PAL PPU |
| ALE + Read | pass/fail and `$5F` (the try that hit, 6 = none) after at least 10 separate power-ons | only 2 of the 5 CPU/PPU alignments can place the read on dot 227 |
| $2004 Stress Test, $2007 Stress Test | pass/fail and error code; on a failure the samples on page 5 | samples 1.6 dots apart checked against the 2C02 keys |
| DMC DMA Bus Conflicts | pass/fail; `$5C/$5D` (the BRK's return address) | the DMA on an opcode fetch at `$4000` reading the controller or `$4015` by bus conflict |
| The five DRAW tests | the values shown | nothing is asserted |

# Success Codes
Some tests have multiple acceptable behaviors that are tested for in this ROM. The behavior used will either be printed on screen after running the test, or you'll see a "success code" on the all-test table.  

### Unofficial Instructions: SHA, SHS
  1: The Address-Bus-High-Byte-Corruption performed a bitwise AND upon ABH with both X and A.  
  2: The Address-Bus-High-Byte-Corruption performed a bitwise AND upon ABH with only X.   
  3: The Address-Bus-High-Byte-Corruption included a magic number to be bitwise ORed with ABH, or did not occur at all.  

### DMA + $2002 Read
  1: The DMC Load DMA occurred after 2 APU cycles. (The common behavior)  
  2: The DMC Load DMA occurred after 3 APU cycles. (The uncommon behavior)  

### DMA + $4016 Read
  1: The controller was read the way a US-released NES / AV Famicom should read controllers.  
  2: The controller was read the way a Famicom should read controllers.  

### APU Register Activation
  1: The controllers were not clocked by the bus conflict with the OAM DMA.  
  2: The controllers were clocked by the bus conflict with the OAM DMA.  

### Implicit DMA Abort
  1: A sample ending in the same APU cycle as the reload was followed by an unexpected extra DMA (as on a mid-1990 or later 2A03).  
  2: No unexpected DMA (as on a pre-mid-1990 2A03). Which one a 2A07 shows is not known; both pass.  

### Controller Clocking
  1: The controller was read the way a US-released NES / AV Famicom should read controllers.  
  2: The controller was read the way a Famicom should read controllers.  

### DMA Landing on Write
  1: The DMC Load DMA occurred after 2 APU cycles. (The common behavior)  
  2: The DMC Load DMA occurred after 3 APU cycles. (The uncommon behavior)  
  
### PPU Read Buffer
  E: The Picture Processing Unit behaved like revision E or earlier.  
  G: The Picture Processing Unit behaved like revision G or earlier.  

### Address $2004 Behavior
  E: The Picture Processing Unit behaved like revision E or earlier.  
  G: The Picture Processing Unit behaved like revision G or earlier.  

# Removed Tests
Tests of the original AccuracyCoin that are not in this ROM:

### RMW $2007 Extra Write
  (Removed due to several revision G PPUs failing this test. More research is needed.)  
  1: A Read-Modify-Write instruction to address $2007 should perform an extra write where the low byte of the PPU address written is the result of the Read-Modify-Write instruction.  
  2: This extra write should not occur when "v" is pointing to Palette RAM. (An extra write still might occur, but that's not the one we're testing for.)  
  3: If "v" is pointing to Palette RAM, this extra write should not get written to the nametable.

### CPU Registers Power On State
  (removed due to a recent discovery where many consoles were found to have noise in these registers at power on. The values trend towards zero, but there's occasionally an extra bit set. Notably the zero flag has been seen to be set at power on multiple times.)  
  (This test still exists in the ROM as a "DRAW" test.)  
  1: The A Register should be $00 at power on.  
  2: The X Register should be $00 at power on.  
  3: The Y Register should be $00 at power on.  
  4: The Stack Pointer should be $FD at power on.  
  5: The Interrupt Flag should be set at power on.

### Unofficial Instructions
  (removed because this test no longer needs to exist. I have individual tests for every non-NOP unofficial opcode.)  
  1: Does "SLO Absolute" do vaguely what's expected of it?  
  2: Does "ANC Immediate" do vaguely what's expected of it?  
  3: Does "RLA Absolute" do vaguely what's expected of it?  
  4: Does "SRE Absolute" do vaguely what's expected of it?  
  5: Does "ASR Immediate" do vaguely what's expected of it?  
  6: Does "RRA Absolute" do vaguely what's expected of it?  
  7: Does "ARR Immediate" do vaguely what's expected of it?  
  8: Does "SAX Absolute" do vaguely what's expected of it?  
  9: Does "ANE Immediate" do vaguely what's expected of it?  
  A: Does "SHA Absolute, Y" do vaguely what's expected of it?  
  B: Does "SHX Absolute, Y" do vaguely what's expected of it?  
  C: Does "SHY Absolute, X" do vaguely what's expected of it?  
  D: Does "SHS Absolute, Y" do vaguely what's expected of it?  
  E: Does "SHA (Indirect) Y" do vaguely what's expected of it?  
  F: Does "LAX Absolute" do vaguely what's expected of it?  
  G: Does "LXA Immediate" do vaguely what's expected of it?  
  H: Does "LAE Absolute, Y" do vaguely what's expected of it?  
  I: Does "DCP Absolute" do vaguely what's expected of it?  
  J: Does "AXS Immediate" do vaguely what's expected of it?  
  K: Does "ISC Absolute" do vaguely what's expected of it?  
  
