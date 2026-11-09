	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	;;            AccuracyCoin PAL            ;;
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	
	; This ROM is a collection of accuracy tests on an NROM cartridge.
	; NOTE: While most of these tests are universal to all revisions of the NES board, CPU, and PPU, there are a handful of tests that are not going to pass on all revisions.
	; To be more specific, these tests were designed for an RP2A03G APU/CPU, and an RP2C02G PPU.
	; PAL port target: Ricoh RP2A07 CPU/APU and RP2C07 PPU.
	; This tree uses PAL frame/VBlank timing in the shared sync layer.
	; Exact dot-level timing tests still need PAL hardware validation;
	; see PAL_PORT.md before treating any result as PAL-accurate.
	;
	; PAL behavior notes for maintainers:
	; - An RP2A07 DMC DMA only halts the CPU on an opcode fetch ([PALDMA]: bus traces of an RP2A07). While halted the CPU
	;   repeats that fetch on every halted cycle, as a 2A03 repeats its read; what the 2A07 never does is halt on a data
	;   read or in the middle of an instruction. Every DMA test in this file is built on that:
	;     * a DMA is observed as an opcode fetched from open bus that the DMA turns into a BRK (TEST_OBProbe_Install),
	;     * opcodes are placed in open bus by PLAs running a program held on the stack (TEST_ImpliedDummyRead_Check),
	;     * stolen cycles are measured against the next DMC DMA (TEST_DOD_Measure) or the frame IRQ (TEST_DAC_Measure,
	;       CycleClock2_Begin).
	;   The boot pre-test writes result_DMCDMASync_PreTest = 2 on such a CPU and DMASync takes DMASyncWithoutOpenBus.
	; - Where the 2A07's behavior has never been measured, the expected value is derived from NESdev's pages for the
	;   2A03 plus the fetch-only rule, and the test says so ("pending hardware"). None of this file has run on a PAL NES.
	; - The SHA/SHX/SHY/SHS tests keep their DMA subtest (error codes 7-C) in a 2A07 form: a DMA requested on the cycle
	;   before the write must change nothing (TEST_UnOp_DMANoEffect).
	; - PAL 4-step half-frame clocks are 16627/33253/49881 CPU cycles; the
	;   5-step clocks are 16627/41565/58193. The PAL tests read one cycle
	;   before the "still playing" boundary and at the "stopped" boundary.
	; - An emulator result is a measurement, not hardware truth.
	; - blargg's pal_apu_tests were tested on a PAL NES and all pass. They
	;   measure the PAL frame sequencer only: bit 6 of $4015 is clear at
	;   33254 CPU clocks after $4017=$00, set at 33255, set again at 33256,
	;   and clear at 33257. This validates
	;   PAL APU frame/length timing, not DMC DMA. See [PALAPU].
	; Additionally, if you run this ROM on your console with a flash cart, you might fail some tests. Notably, the open bus tests fail on an Everdrive N8 Pro.
	;
	; PAL SOURCE TAGS (used by comments in this file):
	; [DMC]     https://www.nesdev.org/wiki/APU_DMC#Pitch_table
	; [FRAME]   https://www.nesdev.org/wiki/APU_Frame_Counter
	; [CYCLE]   https://www.nesdev.org/wiki/Cycle_reference_chart
	; [OPENBUS] https://www.nesdev.org/wiki/Open_bus_behavior
	; [CPU]     https://www.nesdev.org/wiki/CPU_ALL
	; [SYNC]    https://www.nesdev.org/wiki/Consistent_frame_synchronization
	; [DMA]     https://www.nesdev.org/wiki/DMA
	; [MEMMAP]  https://www.nesdev.org/wiki/CPU_memory_map
	; [2A07]    https://www.nesdev.org/wiki/CPU_variants
	; [PALDMA]  https://forums.nesdev.org/viewtopic.php?t=25939 (RP2A07 DMC DMA bus traces, lidnariq/Fiskbit, Apr 2025)
	; [PALDMA2] https://forums.nesdev.org/viewtopic.php?t=26827 (halt attempts and retries, Fiskbit, Sep 2026)
	; [PALRATE] https://forums.nesdev.org/viewtopic.php?t=1468  (PAL DMC rates measured by blargg, May 2006)
	; [PALAPU]  https://github.com/christopherpow/nes-test-roms/tree/master/pal_apu_tests
	;
	; STATUS TAGS:
	; DOC-BACKED        = follows the cited document; not measured on PAL hardware.
	; EMULATOR-MEASURED = observed in an emulator only; not a PAL hardware oracle.
	; UNVERIFIED        = no reliable PAL source or measurement yet; do not use to judge
	;                     a PAL emulator until it has a hardware-derived expectation.
	; HARDWARE-VERIFIED = measured on real PAL RP2A07/RP2C07; none claimed yet.
	
	; If you are looking for a specific test, consider CRTL + F searching for "TestPages:", as that's where the list of tests is.
	; The format for the tests as they are stored in the ROM is:
	; table "Name of test", $FF, Address_To_Store_Test_Results, Address_To_Jump_To_In_Order_To_Run_The_Test
	; so to easily find the code for a test, you can search for the "Address_To_Jump_To_In_Order_To_Run_The_Test:" routine for a given test.
	
	; NOTE: The NMI and IRQ vectors both point to RAM. This allows me to create tests that have different NMI/IRQ routines.
	
	;;;; HEADER AND COMPILER STUFF ;;;;
	.inesprg 2  ; 2 banks
	.ineschr 1  ; 
	.inesmap 0  ; mapper 0 = NROM
	.inesmir 0  ; background mirroring, horizontal
	; NESASM 3.01 has no PAL-timing directive. Run build_pal.py after assembling.
	;;;; CONSTANTS ;;;;	

; PAL reference timing (RP2C07 + RP2A07), used as literal numbers by the waits in this file [CYCLE]:
;   312 scanlines per frame, 70 of them VBlank, pre-render line 311; 106392 PPU dots per frame;
;   33247.5 CPU cycles per frame (fixed waits alternate 33247/33248 where it matters); 7459.375 CPU cycles of VBlank
;   (fixed waits use 7459); the 2C07 refreshes OAM on scanlines 265-310, OAM writes are possible in the first 24
;   scanlines of VBlank.
PAL_APU_FRAME_IRQ_CYCLES = 33254 ; 2A07 4-step IRQ period. [FRAME] DOC-BACKED

flag_c = $1
flag_z = $2
flag_i = $4
flag_v = $40
flag_n = $80	
	

suitePointer = $5
dontSetPointer = $7

byte8 = $8
byte9 = $9

byteF = $F
ErrorCode = $10
initialSubTest = $11
result_DMCDMASync_PreTest = $12
menuTabXPos = $14
menuCursorYPos = $16
menuHeight = $17
controller = $18
controller_New = $19
testAddressPointer = $1A

TestResultPointer = $1E

Test_UnOp_OperandTargetAddrLo = $20
Test_UnOp_OperandTargetAddrHi = $21
Test_UnOp_ValueAtAddressForTest = $22
Test_UnOp_A = $23
Test_UnOp_X = $24
Test_UnOp_Y = $25
Test_UnOp_FlagsInit = $26
Test_UnOp_SP = $27
Test_UnOp_ExpectedResultAddrLo = $28
Test_UnOp_ExpectedResultAddrHi = $29
Test_UnOp_ValueAtAddressResult = $2A
Test_UnOp_CMP = $2B
Test_UnOp_CPX = $2C
Test_UnOp_CPY = $2D
Test_UnOp_CM_Flags = $2E
Test_UnOp_CPS = $2F
Test_UnOp_IndirectPointerLo = $30
Test_UnOp_IndirectPointerHi = $31
Test_UnOp_CycleDelayPostDMA = $32

HighlightTextPrinted = $33
AutomateTestSuite = $34
RunningAllTests = $35
PostAllTestTally = $37
PostAllPassTally = $38
PrintDecimalTensCheck = $39
result_VblankSync_PreTest = $3A
DebugMode = $3B
IncorrectReturnAddressOffset = $3C
AllTestMenuTestNameOffsetLo = $3D
AllTestMenuTestNameOffsetHi = $3E
AllTestMenuTotalSkipped = $3F

; Zero page $21, $61, $A1 and $E1 are where [Implied Dummy Reads] lands a JSR (TEST_ImpliedDummyRead_Check). That test backs
; up and clears the whole zero page itself, so nothing has to be kept away from them.

PostDMACyclesUntilTestInstruction = 13

; Zero page $50-$5F is scratch space for the tests, and $60-$6F as well (rarely used, but engine variables stay out).


TESTHighlightTextCopy = $7A

suiteAttributeCopy = $7E

suitePointerList = $80

suiteExecPointerList = $A0



Reserved_C8 = $C8; For my "unofficial opcodes are correct length" tests, I use [Two-Byte-Opcode][INY], and then check the value of Y. Since INY is $C8, I'd like to avoid corrupting something stored in byte C8.


Debug_EC = $EC 	; This is used to see how far an emulator gets before hanging when loading the main menu.

Copy_X2 = $ED	; These are exclusively used to keep registers from before RunTest from being modified during a test, so they can be restored after the test.
Copy_Y2 = $EE	; ^
Copy_A2 = $EF	; ^

PPUCTRL_COPY = $F0
PPUMASK_COPY = $F1

Copy_SP = $FA
Copy_SP2 = $FB
Copy_Flags = $FC
Copy_X = $FD
Copy_Y = $FE
Copy_A = $FF


PowerOnRAM = $300
PowerOnVRAM = $320
PowerOnPalette = $340
PowerOnTest_PPUReset = $360 ; 1 byte. Pass/fail the PPU Reset flag test.
PowerOn_A = $370
PowerOn_X = $371
PowerOn_Y = $372
PowerOn_SP = $373
PowerOn_P = $374

PowerOn_MagicNumber = $3F0

;$400 to $4FF is where I store the results of the tests.

result_RAMMirror = $0403
result_PPURegMirror = $0404
result_ROMnotWritable = $0405
result_DummyReads = $0406
result_DummyWrites = $0407
result_OpenBus = $0408

result_UnOp_SLO_03 = $409
result_UnOp_SLO_07 = $40A
result_UnOp_SLO_0F = $40B
result_UnOp_SLO_13 = $40C
result_UnOp_SLO_17 = $40D
result_UnOp_SLO_1B = $40E
result_UnOp_SLO_1F = $40F

result_UnOp_ANC_0B	= $410
result_UnOp_ANC_2B	= $411
result_UnOp_ASR_4B	= $412
result_UnOp_ARR_6B	= $413
result_UnOp_ANE_8B	= $414
result_UnOp_LXA_AB	= $415
result_UnOp_AXS_CB	= $416
result_UnOp_SBC_EB	= $417

result_UnOp_RLA_23 = $419
result_UnOp_RLA_27 = $41A
result_UnOp_RLA_2F = $41B
result_UnOp_RLA_33 = $41C
result_UnOp_RLA_37 = $41D
result_UnOp_RLA_3B = $41E
result_UnOp_RLA_3F = $41F

result_UnOp_SRE_43 = $420
result_UnOp_SRE_47 = $47F ; It's pretty funny, but I need address $421 to always be $00. (see Implied Dummy Reads where bit 5 of the opcode is set.)
result_UnOp_SRE_4F = $422
result_UnOp_SRE_53 = $423
result_UnOp_SRE_57 = $424
result_UnOp_SRE_5B = $425
result_UnOp_SRE_5F = $426

result_UnOp_RRA_63 = $427
result_UnOp_RRA_67 = $428
result_UnOp_RRA_6F = $429
result_UnOp_RRA_73 = $42A
result_UnOp_RRA_77 = $42B
result_UnOp_RRA_7B = $42C
result_UnOp_RRA_7F = $42D

result_UnOp_SAX_83 = $42E
result_UnOp_SAX_87 = $42F
result_UnOp_SAX_8F = $430
result_UnOp_SAX_97 = $431
result_UnOp_LAX_A3 = $432
result_UnOp_LAX_A7 = $433
result_UnOp_LAX_AF = $434
result_UnOp_LAX_B3 = $435
result_UnOp_LAX_B7 = $436
result_UnOp_LAX_BF = $437

result_UnOp_DCP_C3 = $438
result_UnOp_DCP_C7 = $439
result_UnOp_DCP_CF = $43A
result_UnOp_DCP_D3 = $43B
result_UnOp_DCP_D7 = $43C
result_UnOp_DCP_DB = $43D
result_UnOp_DCP_DF = $43E

result_UnOp_ISC_E3 = $43F
result_UnOp_ISC_E7 = $440
result_UnOp_ISC_EF = $441
result_UnOp_ISC_F3 = $442
result_UnOp_ISC_F7 = $443
result_UnOp_ISC_FB = $444
result_UnOp_ISC_FF = $445

result_UnOp_SHA_93 = $446
result_UnOp_SHA_9F = $447
result_UnOp_SHS_9B = $448
result_UnOp_SHY_9C = $449
result_UnOp_SHX_9E = $44A
result_UnOp_LAE_BB = $44B

result_DMA_Plus_2007R = $44C
result_ProgramCounter_Wraparound = $44D
result_PPUIOOpenBus = $044E
result_DMA_Plus_2007W = $44F

result_VBlank_Beginning = $450
result_VBlank_End = $451
result_NMI_Control = $452
result_NMI_Timing = $453
result_NMI_Suppression = $454
result_NMI_VBL_End = $455
result_NMI_Disabled_VBL_Start = $456

result_Sprite0Hit_Behavior = $457
result_ArbitrarySpriteZero = $458
result_SprOverflow_Behavior = $459
result_MisalignedOAM_Behavior = $45A
result_Address2004_Behavior = $45B
result_APURegActivation = $45C
result_DMA_Plus_4015R = $45D
result_DMA_Plus_4016R = $45E
result_ControllerStrobing = $45F

result_InstructionTiming = $460
result_IFlagLatency = $461
result_NmiAndBrk = $462
result_NmiAndIrq = $463


result_APULengthCounter = $465
result_APULengthTable = $466
result_FrameCounterIRQ = $467
result_FrameCounter4Step = $468
result_FrameCounter5Step = $469
result_DeltaModulationChannel = $46A
result_DMABusConflict = $46B
result_DMA_Plus_OpenBus = $46C

result_ImpliedDummyRead = $46D

result_AddrMode_AbsIndex = $46E
result_AddrMode_ZPgIndex = $46F
result_AddrMode_Indirect = $470
result_AddrMode_IndIndeX = $471
result_AddrMode_IndIndeY = $472
result_AddrMode_Relative = $473

result_DecimalFlag = $474
result_BFlag = $475

result_PPUReadBuffer = $476

result_DMCDMAPlusOAMDMA = $477
result_ImplicitDMAAbort = $478
result_ExplicitDMAAbort = $479

result_ControllerClocking = $47A

result_OAM_Corruption = $47B

result_JSREdgeCases = $47C
result_AllNOPs = $47D

result_PaletteRAMQuirks = $47E
;	47F is used.If you add a new test, don't forget to skip that value.
result_INC4014 = $480
result_AttributesAsTiles = $481
result_tRegisterQuirks = $482
result_StaleBGShiftRegisters = $483
result_Scanline0Sprites = $484
result_CHRROMIsNotWritable = $485
result_RenderingFlagBehavior = $486
result_BGSerialIn = $487

result_DMA_Plus_2002R = $488
result_SuddenlyResizeSprite = $489
result_Rendering2007Read = $48A
result_BranchDummyRead = $48B
result_2004_Stress = $48C
result_2002FlagClearTiming = $48D
result_2007_Stress = $48E
result_StaleSpriteShiftRegs = $48F

result_InternalDataBus = $490
result_ALERead = $491
result_HybridAddresses = $492
result_FrozenOAM2Inc = $493
result_MisalignedOAMDMA = $494
result_MisalignedOAM2Addr = $495

result_DMALandingOnWrite = $496
result_DMCReloadTiming = $497
result_DMCPlaybackRate = $498

result_DrawTest = $03FF	; page 3 omits the test from the all-test-result-table.

;$500 is dedicated to RAM needed for tests.
;$600 is dedicated to the IRQ routine
;$700 is dedicated to the NMI routine.

	;;;; ASSEMBLY CODE ;;;;
	.org $8000
	; The open bus test needs to make sure an inaccurate emulation of open bus will fall into test code, so this function here is a fail condition of the open bus test.
OpenBusTestFakedOpenBusBehavior:
	NOP	; An incorrect implementation of open bus might execute all the way to here from address $5000.
	NOP	; The two NOPs are for alignment, and this BRK takes the PC to some "test failed" handler.
	BRK	; Pushes 3 bytes to the stack, and moves the PC to the address determined by $FFFE, which is address $0600.
	
CannotWriteToROM_01:
	.byte $01; This value is used in the "Cannot write to ROM" test.
	
RESET:	            ; This ROM, despite the guidance of the NesDev Wiki's "startup code", writes a bunch of uninitialized registers, and reads uninitialized RAM. Intentionally.
	STA <$00		; First thing we do at power on is store A to address $00 as a temporary place to hold it. This does not modify the CPU flags.
	PHP				; Push the processor flags...
	PLA				; ... and pull them off.
	AND #$CF		; Remove the B flag, and other garbage flag.
	STA <$01		; And store this somewhere temporary.
	LDA PowerOn_MagicNumber	; Before we store these to the "test results", let's verify this is a cold boot and not a warm boot.
	CMP #$5A		; Assume a cold boot won't have this value here.
	BEQ RESET_SkipPowerOnTests	; If the value was $5A, skip storing stuff to RAM.
	LDA <$00		; Okay cool, it's a cold boot. Let's start storing some stuff. Copy the value we set aside...
	STA PowerOn_A	; And store the value for use in TEST_PowerOnState_CPU_Registers
	STY PowerOn_Y	; Ditto for the Y register.
	STX PowerOn_X	; And the X register.
	TSX				; Let's fetch the stack pointer...
	STX PowerOn_SP	; And store it for that test.
	LDA <$01		; We stored the flags here, so let's copy these...
	STA PowerOn_P	; And paste it in RAM.
RESET_SkipPowerOnTests:

	SEI		 ; Time for some regular power on code. Fun fact: The I flag is already set at power on and when hitting reset. The CPU just does that. So this line isn't needed.
	CLD		 ; Disable the Decimal Flag. Who knows, maybe you hit reset in the middle of the Decimal Flag test.
	LDX #$EF ; Due to some tests modifying the stack pointer, it's convenient to put it at EF instead of FF.
	TXS		 ; This prevents some tests where the resulting stack pointer is 00 from pushing data, and overwriting the bottom of the stack.
	LDA #$40
	STA $4017; Disable the APU Frame Counter IRQ.
	STA $2000 ; A = $40 here: clear NMI-enable for a warm reset. A stale test NMI routine may still be at $700.
	STA $4015 ; A = $40 here: disable all APU channels and stop a DMC left running by the previous test.
TEST_PPUResetFlag:
	; All throughout this ROM, you will see me label the various tests like so:
	; 3 semicolons, the error code that will appear if the test fails here, the name of the test in square brackets, then a description of what is being tested.
	; Here's an example:
	
	;;; Test 1 [PPU Reset Flag]: Are PPU Registers writable before the first pre-render line? ;;;
	; They shouldn't be, as that's the job of the PPU Reset Flag! (NOTE: Not every console has this behavior!)
	; Let's see if the PPU Reset flag exists.
	LDA #$27
	STA $2006 ; "magic address" (Writing to $2006 twice will update the 'v' register of the PPU)
	LDA #$BF
	STA $2006 ; 'v' = $27BF
	LDA #$5A  ; "magic number". All over this ROM, you will frequently see me using the value $5A for tests. That's 01011010 in binary, and I just assume that if something goes wrong, it won't stumble on that number by random chance.
	STA $2007
	; Okay, I'll be back in 2 frames to check on you...
	LDX #$FF  ; We're going to stall for VBlank, increment X, then X=0, so we're going to stall until next VBlank yet again.
	LDA $2002
VblLoop:
	LDA $2002   ; This is PPU_STATUS. Bit 7 tells us if the PPU is currently in VBlank or not.
	BPL VblLoop ; So if bit 7 is 0 (we are not in VBlank) the Negative flag is not set, so "Branch of Plus" will be taken.
	INX	; X++
	BEQ VblLoop ; If X is zero, we do this again.
	; Now that the PPU is responsive, let's copy the resting values.
	LDA PowerOn_MagicNumber	; Check again if this is a cold or a warm boot.
	CMP #$5A				
	BEQ PostResetFlagTest	; If this is a warm boot, skip copying the uninitialized RAM and VRAM.

	JSR Read32NametableBytes
	JSR ReadPaletteRAM
	
	; Let's also see if the magic number was written to VRAM, to verify if the reset flag exists.
	; It's worth noting that in its current state, this test fails on my console. I assume this has something to do with the flash cart I'm using.
	LDA #6
	STA PowerOnTest_PPUReset ; set to FAIL (error code $1) by default. Overwrite with PASS if it passes.
	LDA #$27
	STA $2006
	LDA #$BF
	STA $2006 ; Set 'v' back to where we attempted to write our magic number.
	LDA $2007 ; load buffer
	LDA $2007 ; read buffer
	CMP #$5A
	BEQ PostResetFlagTest	; If A = $5A at this point, you fail the test since that means we wrote to VRAM before the PPU reset flag cleared. (Or uninitialized VRAM there was $5A?)
	; The value of $5A was not written to VRAM, so the reset flag does exist!
	LDA #1
	STA PowerOnTest_PPUReset ; Store a passing result here.
	; I also indicate whenever a test is over with the following comment:
	;; END OF TEST ;;		
PostResetFlagTest:	
	JSR DisableRendering
	
	; With uninitialized values from VRAM and Palette RAM copied for future reference, let's overwrite the palette and nametable.
	JSR SetUpDefaultPalette
	JSR ClearRAMExceptPage3 ; Page 3 holds a copy of uninitialized RAM, VRAM, Palette RAM...
	JSR VerifyJSRBehavior
	JSR ClearNametable
	LDA #$5A
	STA PowerOn_MagicNumber ; At this point, let's write out magic number to RAM, indicating that any reset after this point is a warm boot.
							; So now if the reset button is pressed, we skip writing to the results of TEST_PowerOnState_CPU_Registers, and skip running the PPU reset flag test.
							; I guess that means you could hit the reset button at any point before this to ruin the results of those tests.
							; I'm not sure why you would do that though...
ReloadMainMenu: ; There's an option to run every test in the ROM, and it draws a table of the results. This will run when exiting that screen with the table.
	; If your emulator fails to reach the main menu of this ROM, check the value of address $EC.
	; This can help inform you of specifically where your emulator hangs.
	; A soft reset does not reset OAMADDR, and a test can leave it nonzero.
	; Start the menu's 256-byte OAM DMA at address 0 so menu sprites are not shifted.
	LDA #0
	STA $2003
	INC <Debug_EC ; 00 -> 01
	JSR ClearPage2 ; Page 2 is used for OAM.
	JSR OAMDMAWithPage2
	
	LDA #0
	STA <dontSetPointer
	INC <Debug_EC ; 01 -> 02
	; set up the NMI routine.
	JSR SetUpNMIRoutineForMainMenu
	
	LDA #0
	
	STA $6000 ; An incorrect open bus implementation might end up executing address $6000, so let's initialize these 3 bytes to BRKs.
	STA $6001 ; Though I would prefer if this was a NES 2.0 cartridge without any PRG RAM, so writing here might do nothing anyway.
	STA $6002 ; There's still a good chance an emulator doesn't support NES 2.0 and just puts PRG RAM here anyway.
	
	; No code here: the OAMADDR write above is paid for by the cycles that the 2A03 build spends on debug increments at
	; this point, so DMASync's PPU phase is the same as upstream's. DMASync's open-bus loop is phase-sensitive.
	JSR WaitForVBlank
	JSR TEST_VblankSync_PreTest; Initialize result_VblankSync_PreTest
	JSR DMASync ; Initialize result_DMCDMASync_PreTest
	; The ROM measures this instead of assuming it. On a real 2A07 the result is 2: its DMA only halts the
	; CPU on an opcode fetch (NESdev forum "PAL DMA behavior", RP2A07 bus traces), so an open-bus read never shows the
	; DMA's byte.
	
	LDA #$FF
	STA <menuCursorYPos
	
	LDA #Low(Suite_CPUBehavior)
	STA <suitePointer
	LDA #High(Suite_CPUBehavior)
	STA <suitePointer+1
	INC <Debug_EC ; 06 -> 07
	JSR LoadSuiteMenu	; Determine all the tests on the current page, and store the pointers in RAM.
	INC <Debug_EC ; 07 -> 08
	JSR DrawPageNumber	; Draw the correct page number at the top of the screen.
	INC <Debug_EC ; 08 -> 09
	JSR WaitForVBlank	; Stall until the PPU is in VBlank.
	JSR ResetScroll		; Set the ppu 'v' and 't' registers to $2000, and reset the fine scroll values as well.
	JSR EnableFullRendering; Enable rendering the background.
	JSR EnableNMI		; Enable the Non Maskable Interrupt.
	INC <Debug_EC ; 09 -> 0A
	; If your emulator hangs here, you probably haven't implemented the NMI?
	
InfiniteLoop:
	JMP InfiniteLoop	; This is the spinning loop while I wait for the NMI to occur.
;;;;;;;;;;;;;;;;;;;;
	
VerifyJSRBehavior:
	; Let's also verify that JSR is pushing the correct values to the stack.
	; A handful of my subroutines pull off the values pushed by JSR, and use them to read data stored next to the JSR instruction.
	; I need my code to still be able to load the menu even if the JSR return addresses are wrong.
	; To verify this, I'll just put a JSR at address $0000, and jump there.
	LDA #$20 ; JSR
	STA <$00
	LDA #Low(VerifyReturnAddressesAreCorrect)
	STA <$01
	LDA #High(VerifyReturnAddressesAreCorrect)
	STA <$02
	LDA #$60 ; RTS
	STA <$03
	; This debug-only increment is replaced by a NOP so the JSR below
	; returns to $80FF and its RTS still fits before the table at $8100.
	NOP
	JSR $0000 ; Verify return addresses pushed by JSR are correct.	
	RTS
;;;;;;;
	
	.org $8100
	; Menu Data

	; Here is how the pages of tests are organized.
TableTable:
	.word Suite_CPUBehavior
	.word Suite_CPUInstructions
	.word Suite_UnofficialOps_SLO
	.word Suite_UnofficialOps_RLA
	.word Suite_UnofficialOps_SRE
	.word Suite_UnofficialOps_RRA
	.word Suite_UnofficialOps__AX
	.word Suite_UnofficialOps_DCP
	.word Suite_UnofficialOps_ISC
	.word Suite_UnofficialOps_SH_
	.word Suite_UnofficialOps_Immediates
	.word Suite_CPUInterrupts
	.word Suite_DMATests
	.word Suite_APUTiming
	.word Suite_CPUBehavior2
	.word Suite_PowerOnState
	.word Suite_PPUBehavior
	.word Suite_PPUTiming
	.word Suite_SpriteZeroHits
	.word Suite_PPUMisc
	.word Suite_AdvancedBGEval
	.word Suite_AdvancedSpriteEval
EndTableTable:

	; I'm not a huge fan of using macros in this ROM, since they make the ASM code look different than the compiled bytes, and thus harder to debug.
	; This macro is just a series of bytes and words though, so it's not too hard to read.
table .macro
	.byte \1
	.byte \2
	.word \3
	.word \4
	.endm
	
	; This is just an absurd byte-saving measure where I substitute the word "absolute" for a single character in the ROM.
tblf1 .macro
	.byte \1
	.byte \2
	.byte \3
	.word \4
	.word \5
	.endm
	
	; This is just an absurd byte-saving measure where I substitute the word "absolute" for a single character in the ROM, but then I need to add a ",X" afterwards.
tblf2 .macro
	.byte \1
	.byte \2
	.byte \3
	.byte \4
	.word \5
	.word \6
	.endm

str_Indirect = $F0
str_ZeroPage = $F1
str_Absolute = $F2
str_Immediate = $F3
str_UnofficialInstructions = $F4

TestPages:	; I just made this label for ease of searching.

	;; CPU Behavior ;;
Suite_CPUBehavior:
	.byte "CPU Behavior", $FF
	table "ROM is not writable",  $FF, result_ROMnotWritable,            TEST_ROMnotWritable
	table "RAM Mirroring",        $FF, result_RAMMirror,                 TEST_RamMirroring
	table "PC Wraparound",        $FF, result_ProgramCounter_Wraparound, Test_ProgramCounter_Wraparound
	table "The Decimal Flag",     $FF, result_DecimalFlag,               TEST_DecimalFlag
	table "The B Flag",           $FF, result_BFlag,                     TEST_BFlag
	table "Dummy read cycles",    $FF, result_DummyReads,                TEST_DummyReads
	table "Dummy write cycles",   $FF, result_DummyWrites,               TEST_DummyWrites
	table "Open Bus",             $FF, result_OpenBus,                   TEST_OpenBus
	table "All NOP instructions", $FF, result_AllNOPs,                   TEST_AllNOPs
	.byte $FF
	
Suite_CPUInstructions:
	.byte "Addressing mode wraparound", $FF
	table "Absolute Indexed",  $FF, result_AddrMode_AbsIndex, TEST_AddrMode_AbsIndex
	table "Zero Page Indexed", $FF, result_AddrMode_ZPgIndex, TEST_AddrMode_ZPgIndex
	table "Indirect",          $FF, result_AddrMode_Indirect, TEST_AddrMode_Indirect
	table "Indirect, X",       $FF, result_AddrMode_IndIndeX, TEST_AddrMode_IndIndeX
	table "Indirect, Y",       $FF, result_AddrMode_IndIndeY, TEST_AddrMode_IndIndeY
	table "Relative",          $FF, result_AddrMode_Relative, TEST_AddrMode_Relative
	.byte $FF
	
	;; Unofficial Instructions: SLO ;;
Suite_UnofficialOps_SLO:
	.byte str_UnofficialInstructions
	.byte "SLO", $FF
	tblf2 "$03   SLO", str_Indirect, ",X", $FF, result_UnOp_SLO_03, TEST_SLO_03
	tblf1 "$07   SLO", str_ZeroPage,       $FF, result_UnOp_SLO_07, TEST_SLO_07
	tblf1 "$0F   SLO", str_Absolute,       $FF, result_UnOp_SLO_0F, TEST_SLO_0F
	tblf2 "$13   SLO", str_Indirect, ",Y", $FF, result_UnOp_SLO_13, TEST_SLO_13
	tblf2 "$17   SLO", str_ZeroPage, ",X", $FF, result_UnOp_SLO_17, TEST_SLO_17
	tblf2 "$1B   SLO", str_Absolute, ",Y", $FF, result_UnOp_SLO_1B, TEST_SLO_1B
	tblf2 "$1F   SLO", str_Absolute, ",X", $FF, result_UnOp_SLO_1F, TEST_SLO_1F
	.byte $FF
	
	;; Unofficial Instructions: RLA ;;
Suite_UnofficialOps_RLA:
	.byte str_UnofficialInstructions
	.byte "RLA", $FF
	tblf2 "$23   RLA", str_Indirect, ",X", $FF, result_UnOp_RLA_23, TEST_RLA_23
	tblf1 "$27   RLA", str_ZeroPage,       $FF, result_UnOp_RLA_27, TEST_RLA_27
	tblf1 "$2F   RLA", str_Absolute,       $FF, result_UnOp_RLA_2F, TEST_RLA_2F
	tblf2 "$33   RLA", str_Indirect, ",Y", $FF, result_UnOp_RLA_33, TEST_RLA_33
	tblf2 "$37   RLA", str_ZeroPage, ",X", $FF, result_UnOp_RLA_37, TEST_RLA_37
	tblf2 "$3B   RLA", str_Absolute, ",Y", $FF, result_UnOp_RLA_3B, TEST_RLA_3B
	tblf2 "$3F   RLA", str_Absolute, ",X", $FF, result_UnOp_RLA_3F, TEST_RLA_3F
	.byte $FF
	
	;; Unofficial Instructions: SRE ;;
Suite_UnofficialOps_SRE:
	.byte str_UnofficialInstructions
	.byte "SRE", $FF
	tblf2 "$43   SRE", str_Indirect, ",X", $FF, result_UnOp_SRE_43, TEST_SRE_43
	tblf1 "$47   SRE", str_ZeroPage,       $FF, result_UnOp_SRE_47, TEST_SRE_47
	tblf1 "$4F   SRE", str_Absolute,       $FF, result_UnOp_SRE_4F, TEST_SRE_4F
	tblf2 "$53   SRE", str_Indirect, ",Y", $FF, result_UnOp_SRE_53, TEST_SRE_53
	tblf2 "$57   SRE", str_ZeroPage, ",X", $FF, result_UnOp_SRE_57, TEST_SRE_57
	tblf2 "$5B   SRE", str_Absolute, ",Y", $FF, result_UnOp_SRE_5B, TEST_SRE_5B
	tblf2 "$5F   SRE", str_Absolute, ",X", $FF, result_UnOp_SRE_5F, TEST_SRE_5F
	.byte $FF
	
	;; Unofficial Instructions: RRA ;;
Suite_UnofficialOps_RRA:
	.byte str_UnofficialInstructions
	.byte "RRA", $FF
	tblf2 "$63   RRA", str_Indirect, ",X", $FF, result_UnOp_RRA_63, TEST_RRA_63
	tblf1 "$67   RRA", str_ZeroPage,       $FF, result_UnOp_RRA_67, TEST_RRA_67
	tblf1 "$6F   RRA", str_Absolute,       $FF, result_UnOp_RRA_6F, TEST_RRA_6F
	tblf2 "$73   RRA", str_Indirect, ",Y", $FF, result_UnOp_RRA_73, TEST_RRA_73
	tblf2 "$77   RRA", str_ZeroPage, ",X", $FF, result_UnOp_RRA_77, TEST_RRA_77
	tblf2 "$7B   RRA", str_Absolute, ",Y", $FF, result_UnOp_RRA_7B, TEST_RRA_7B
	tblf2 "$7F   RRA", str_Absolute, ",X", $FF, result_UnOp_RRA_7F, TEST_RRA_7F
	.byte $FF
	
	;; Unofficial Instructions: .AX ;;
Suite_UnofficialOps__AX:
	.byte str_UnofficialInstructions
	.byte "*AX", $FF
	tblf2 "$83   SAX", str_Indirect, ",X", $FF, result_UnOp_SAX_83, TEST_SAX_83
	tblf1 "$87   SAX", str_ZeroPage,       $FF, result_UnOp_SAX_87, TEST_SAX_87
	tblf1 "$8F   SAX", str_Absolute,       $FF, result_UnOp_SAX_8F, TEST_SAX_8F
	tblf2 "$97   SAX", str_ZeroPage, ",Y", $FF, result_UnOp_SAX_97, TEST_SAX_97
	tblf2 "$A3   LAX", str_Indirect, ",X", $FF, result_UnOp_LAX_A3, TEST_LAX_A3
	tblf1 "$A7   LAX", str_ZeroPage,       $FF, result_UnOp_LAX_A7, TEST_LAX_A7
	tblf1 "$AF   LAX", str_Absolute,       $FF, result_UnOp_LAX_AF, TEST_LAX_AF
	tblf2 "$B3   LAX", str_Indirect, ",Y", $FF, result_UnOp_LAX_B3, TEST_LAX_B3
	tblf2 "$B7   LAX", str_ZeroPage, ",Y", $FF, result_UnOp_LAX_B7, TEST_LAX_B7
	tblf2 "$BF   LAX", str_Absolute, ",Y", $FF, result_UnOp_LAX_BF, TEST_LAX_BF
	.byte $FF
	
	;; Unofficial Instructions: DCP ;;
Suite_UnofficialOps_DCP:
	.byte str_UnofficialInstructions
	.byte "DCP", $FF
	tblf2 "$C3   DCP", str_Indirect, ",X", $FF, result_UnOp_DCP_C3, TEST_DCP_C3
	tblf1 "$C7   DCP", str_ZeroPage,       $FF, result_UnOp_DCP_C7, TEST_DCP_C7
	tblf1 "$CF   DCP", str_Absolute,       $FF, result_UnOp_DCP_CF, TEST_DCP_CF
	tblf2 "$D3   DCP", str_Indirect, ",Y", $FF, result_UnOp_DCP_D3, TEST_DCP_D3
	tblf2 "$D7   DCP", str_ZeroPage, ",X", $FF, result_UnOp_DCP_D7, TEST_DCP_D7
	tblf2 "$DB   DCP", str_Absolute, ",Y", $FF, result_UnOp_DCP_DB, TEST_DCP_DB
	tblf2 "$DF   DCP", str_Absolute, ",X", $FF, result_UnOp_DCP_DF, TEST_DCP_DF
	.byte $FF
	
	;; Unofficial Instructions: ISC ;;
Suite_UnofficialOps_ISC:
	.byte str_UnofficialInstructions
	.byte "ISC", $FF
	tblf2 "$E3   ISC", str_Indirect, ",X", $FF, result_UnOp_ISC_E3, TEST_ISC_E3
	tblf1 "$E7   ISC", str_ZeroPage,       $FF, result_UnOp_ISC_E7, TEST_ISC_E7
	tblf1 "$EF   ISC", str_Absolute,       $FF, result_UnOp_ISC_EF, TEST_ISC_EF
	tblf2 "$F3   ISC", str_Indirect, ",Y", $FF, result_UnOp_ISC_F3, TEST_ISC_F3
	tblf2 "$F7   ISC", str_ZeroPage, ",X", $FF, result_UnOp_ISC_F7, TEST_ISC_F7
	tblf2 "$FB   ISC", str_Absolute, ",Y", $FF, result_UnOp_ISC_FB, TEST_ISC_FB
	tblf2 "$FF   ISC", str_Absolute, ",X", $FF, result_UnOp_ISC_FF, TEST_ISC_FF
	.byte $FF
	
	;; Unofficial Instructions: SH_ ;;
Suite_UnofficialOps_SH_:
	.byte str_UnofficialInstructions
	.byte "SH*", $FF
	tblf2 "$93   SHA", str_Indirect, ",Y", $FF, result_UnOp_SHA_93, TEST_SHA_93
	tblf2 "$9F   SHA", str_Absolute, ",Y", $FF, result_UnOp_SHA_9F, TEST_SHA_9F
	tblf2 "$9B   SHS", str_Absolute, ",Y", $FF, result_UnOp_SHS_9B, TEST_SHS_9B
	tblf2 "$9C   SHY", str_Absolute, ",X", $FF, result_UnOp_SHY_9C, TEST_SHY_9C
	tblf2 "$9E   SHX", str_Absolute, ",Y", $FF, result_UnOp_SHX_9E, TEST_SHX_9E
	tblf2 "$BB   LAE", str_Absolute, ",Y", $FF, result_UnOp_LAE_BB, TEST_LAE_BB
	.byte $FF
	
	;; Unofficial Instructions: The Immediate group ;;
Suite_UnofficialOps_Immediates:
	.byte "Unofficial Immediates", $FF
	tblf1 "$0B   ANC", str_Immediate, $FF, result_UnOp_ANC_0B, TEST_ANC_0B
	tblf1 "$2B   ANC", str_Immediate, $FF, result_UnOp_ANC_2B, TEST_ANC_2B
	tblf1 "$4B   ASR", str_Immediate, $FF, result_UnOp_ASR_4B, TEST_ASR_4B
	tblf1 "$6B   ARR", str_Immediate, $FF, result_UnOp_ARR_6B, TEST_ARR_6B
	tblf1 "$8B   ANE", str_Immediate, $FF, result_UnOp_ANE_8B, TEST_ANE_8B
	tblf1 "$AB   LXA", str_Immediate, $FF, result_UnOp_LXA_AB, TEST_LXA_AB
	tblf1 "$CB   AXS", str_Immediate, $FF, result_UnOp_AXS_CB, TEST_AXS_CB
	tblf1 "$EB   SBC", str_Immediate, $FF, result_UnOp_SBC_EB, TEST_SBC_EB
	.byte $FF
	
	;; CPU Interrupts ;;
Suite_CPUInterrupts:
	.byte "CPU Interrupts", $FF
	table "Interrupt flag latency", $FF, result_IFlagLatency, TEST_IFlagLatency
	table "NMI Overlap BRK",        $FF, result_NmiAndBrk,    TEST_NmiAndBrk
	table "NMI Overlap IRQ",        $FF, result_NmiAndIrq,    TEST_NmiAndIrq
	.byte $FF
	
	;; DMA Tests ;;
Suite_DMATests:
	.byte "APU Registers and DMA tests", $FF	
	table "DMA + Open Bus",        $FF, result_DMA_Plus_OpenBus, TEST_DMA_Plus_OpenBus
	table "DMA + $2002 Read",      $FF, result_DMA_Plus_2002R,   TEST_DMA_Plus_2002R
	table "DMA + $2007 Read",      $FF, result_DMA_Plus_2007R,   TEST_DMA_Plus_2007R
	table "DMA + $2007 Write",     $FF, result_DMA_Plus_2007W,   TEST_DMA_Plus_2007W
	table "DMA + $4015 Read",      $FF, result_DMA_Plus_4015R,   TEST_DMA_Plus_4015R
	table "DMA + $4016 Read",      $FF, result_DMA_Plus_4016R,   TEST_DMA_Plus_4016R
	table "DMC DMA Bus Conflicts", $FF, result_DMABusConflict,   TEST_DMABusConflict
	table "DMC DMA + OAM DMA",     $FF, result_DMCDMAPlusOAMDMA, TEST_DMCDMAPlusOAMDMA
	table "Explicit DMA Abort",    $FF, result_ExplicitDMAAbort, TEST_ExplicitDMAAbort
	table "Implicit DMA Abort",    $FF, result_ImplicitDMAAbort, TEST_ImplicitDMAAbort
	.byte $FF
	
	;; APU Tests ;;
Suite_APUTiming:
	.byte "APU Tests", $FF
	table "Length Counter",           $FF, result_APULengthCounter,       TEST_APULengthCounter
	table "Length Table",             $FF, result_APULengthTable,         TEST_APULengthTable
	table "Frame Counter IRQ",        $FF, result_FrameCounterIRQ,        TEST_FrameCounterIRQ
	table "Frame Counter 4-step",     $FF, result_FrameCounter4Step,      TEST_FrameCounter4Step
	table "Frame Counter 5-step",     $FF, result_FrameCounter5Step,      TEST_FrameCounter5Step
	table "Delta Modulation Channel", $FF, result_DeltaModulationChannel, TEST_DeltaModulationChannel
	table "APU Register Activation",  $FF, result_APURegActivation,       TEST_APURegActivation
	table "Controller Strobing",      $FF, result_ControllerStrobing,     TEST_ControllerStrobing
	table "Controller Clocking",      $FF, result_ControllerClocking,     TEST_ControllerClocking
	.byte $FF

	;; CPU Behavior 2 ;;
Suite_CPUBehavior2:
	.byte "CPU Behavior 2", $FF
	table "Instruction Timing",   $FF, result_InstructionTiming, TEST_InstructionTiming
	table "Implied Dummy Reads",  $FF, result_ImpliedDummyRead,  TEST_ImpliedDummyRead
	table "Branch Dummy Reads",   $FF, result_BranchDummyRead,   TEST_BranchDummyRead
	table "JSR Edge Cases",       $FF, result_JSREdgeCases,      TEST_JSREdgeCases
	table "Internal Data Bus",    $FF, result_InternalDataBus,   TEST_InternalDataBus
	table "DMA Landing on Write", $FF, result_DMALandingOnWrite, TEST_DMALandingOnWrite
	table "DMC Reload Timing",    $FF, result_DMCReloadTiming,   TEST_DMCReloadTiming
	table "DMC Playback Rate", $FF, result_DMCPlaybackRate,   TEST_DMCPlaybackRate
	.byte $FF

	;; Power On State ;;
Suite_PowerOnState:
	.byte "Power On State", $FF
	table "PPU Reset Flag", $FF, result_DrawTest,   TEST_PowerOnState_PPU_ResetFlag
	table "CPU RAM",        $FF, result_DrawTest,   TEST_PowerOnState_CPU_RAM
	table "CPU Registers",  $FF, result_DrawTest,   TEST_PowerOnState_CPU_Registers
	table "PPU RAM",        $FF, result_DrawTest,   TEST_PowerOnState_PPU_RAM
	table "Palette RAM",    $FF, result_DrawTest,   TEST_PowerOnState_PPU_Palette
	.byte $FF
	
	;; PPU Behavior ;;
Suite_PPUBehavior:
	.byte "PPU Behavior", $FF
	table "CHR ROM is not writable", $FF, result_CHRROMIsNotWritable,   TEST_CHRROMIsNotWritable
	table "PPU Register Mirroring",  $FF, result_PPURegMirror,          TEST_PPURegMirroring
	table "PPU Register Open Bus",	 $FF, result_PPUIOOpenBus,          TEST_PPU_IO_Open_Bus
	table "PPU Read Buffer",         $FF, result_PPUReadBuffer,         TEST_PPUReadBuffer
	table "Palette RAM Quirks",      $FF, result_PaletteRAMQuirks,      TEST_PaletteRAMQuirks
	.byte $FF
	
	;; PPU VBL Timing ;;
Suite_PPUTiming:
	.byte "PAL Timing", $FF
	table "VBlank beginning",       $FF, result_VBlank_Beginning,       TEST_VBlank_Beginning
	table "VBlank end",             $FF, result_VBlank_End,             TEST_VBlank_End
	table "NMI Control",            $FF, result_NMI_Control,           TEST_NMI_Control
	table "NMI Timing",             $FF, result_NMI_Timing,            TEST_NMI_Timing
	table "NMI Suppression",        $FF, result_NMI_Suppression,       TEST_NMI_Suppression
	table "NMI at VBlank end",      $FF, result_NMI_VBL_End,            TEST_NMI_VBL_End
	table "NMI disabled at VBlank", $FF, result_NMI_Disabled_VBL_Start, TEST_NMI_Disabled_VBL_Start
	.byte $FF
	
	;; Sprite Zero Hits ;;
Suite_SpriteZeroHits:
	.byte "Sprite Evaluation", $FF
	table "Sprite overflow behavior", $FF, result_SprOverflow_Behavior,   TEST_SprOverflow_Behavior
	table "Sprite 0 Hit behavior",         $FF, result_Sprite0Hit_Behavior,    TEST_Sprite0Hit_Behavior
	table "$2002 flag timing",       $FF, result_2002FlagClearTiming,    TEST_2002FlagTiming
	table "Suddenly Resize Sprite",  $FF, result_SuddenlyResizeSprite,   TEST_SuddenlyResizeSprite
	table "Misaligned OAM DMA",       $FF, result_MisalignedOAMDMA,       TEST_MisalignedOAMDMA
	table "Arbitrary Sprite zero",    $FF, result_ArbitrarySpriteZero,    TEST_ArbitrarySpriteZero
	table "Misaligned OAM behavior",      $FF, result_MisalignedOAM_Behavior, TEST_MisalignedOAM_Behavior
	table "OAM Corruption",   $FF, result_OAM_Corruption,         TEST_OAM_Corruption
	.byte $FF
	
	;; PPU Misc ;;
Suite_PPUMisc:
	.byte "PPU Misc.", $FF
	table "t Register Quirks",        $FF, result_tRegisterQuirks,       TEST_tRegisterQuirks
	table "Address $2004 behavior",   $FF, result_Address2004_Behavior,  TEST_Address2004_Behavior
	table "INC $4014",                $FF, result_INC4014,               TEST_INC4014
	table "Rendering Flag Behavior",  $FF, result_RenderingFlagBehavior, TEST_RenderingFlagBehavior
	table "$2007 read w/ rendering",  $FF, result_Rendering2007Read,     TEST_Rendering2007Read
	table "$2004 Stress Test",        $FF, result_2004_Stress,           TEST_2004_Stress
	table "$2007 Stress Test",        $FF, result_2007_Stress,           TEST_2007_Stress


	; Not in this suite: "RMW $2007 Extra Write" (more research required) and "Palette Corruption" (it relies on a
	; specific CPU/PPU clock alignment).
	.byte $FF
	
Suite_AdvancedBGEval:
	.byte "Advanced Background Evaluation", $FF
	table "Attributes As Tiles",      $FF, result_AttributesAsTiles,     TEST_AttributesAsTiles
	table "Stale BG Shift Registers", $FF, result_StaleBGShiftRegisters, TEST_StaleBGShiftRegisters
	table "BG Serial In",                     $FF, result_BGSerialIn,            TEST_BGSerialIn
	table "ALE + Read",               $FF, result_ALERead,               TEST_ALERead
	table "Hybrid Addresses",         $FF, result_HybridAddresses,       TEST_HybridAddresses
	.byte $FF
	
Suite_AdvancedSpriteEval:
	.byte "Advanced Sprite Evaluation", $FF
	table "Sprites On Scanline 0",   $FF, result_Scanline0Sprites,     TEST_Scanline0Sprites
	table "Stale Sprite Shift Regs", $FF, result_StaleSpriteShiftRegs, TEST_StaleSpriteShiftRegs
	table "Frozen OAM2 Increment",   $FF, result_FrozenOAM2Inc,        TEST_FrozenOAM2Inc
	table "Misaligned OAM2 Address", $FF, result_MisalignedOAM2Addr,   TEST_MisalignedOAM2Addr

	.byte $FF



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;           MORE ENGINE STUFF             ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; I ran out of space in the engine section from $F000 - $FFFF, so I put some extra stuff here.

AutomaticallyRunEveryTestInROM:   ; This function is used to run every test in the ROM automatically.
	LDA #1
	STA <RunningAllTests          ; The "RunningAllTests" variable is used to prevent any graphical changes to the "running all tests screen".
	JSR DisableNMI                ; Disable the NMI.
	JSR DisableRendering		  ; Disable rendering.
	JSR ClearNametable			  ; Clear the nametable.
	LDA #0
	STA <dontSetPointer
	JSR PrintText				  ; Print "Running test 0" on screen.
	.word $21E8
	.byte "Running test 0", $FF
	JSR ResetScroll				  ; And fix the PPU scroll.
	LDY #0
	STY <PostAllTestTally
AutomaticallyRunEntireROM_Loop:
	JSR ResetScroll
	STY <menuTabXPos
	JSR SetUpSuitePointer         ; Set up the suite pointer.
	JSR LoadSuiteMenuNoRendering  ; Set up the menuHeight, and all the pointers for these tests and results.
	LDX #0
	JSR WaitForVBlank
AutomaticallyRunEntireROM_Loop2:  ; Run every test on page Y.
	TXA
	PHA
	ASL A
	TAX
	LDA <suitePointerList+1,X
	STA <$00
	PLA
	TAX
	LDA <$00
	CMP #3	; if the page used to store the results is page 3 instead of page 4, we skip this test.
	BEQ AREROM_RT_Skip
	STX <menuCursorYPos           ; The "menuCursorYPos" variable is used inside RunTest to determine what code to run.
	PHA
	TXA
	PHA
	TYA
	PHA
	LDA #$21
	STA $2006
	LDA #$F5
	STA $2006
	INC <PostAllTestTally
	LDA <PostAllTestTally
	JSR PrintByteDecimal_MinDigits
	JSR PrintTestName
	PLA
	TAY
	PLA
	TAX
	PLA
	JSR RunTest                   ; Run the test at index X of page Y.
	JSR WaitForVBlank
AREROM_RT_Skip:
	INX                           ; increment X until X=MenuHeight.
	CPX <menuHeight
	BNE AutomaticallyRunEntireROM_Loop2
	                              ; That was all the tests on page Y.
	INY                           ; Y++
	CPY #((EndTableTable - TableTable)/2) ; Compare Y with the total page count.
	BNE AutomaticallyRunEntireROM_Loop    ; And loop if there are more pages to run.
	; All tests are complete!
	LDA #0
	STA $4015
	JSR WaitForVBlank             ; Wait for VBland for the PPU register writes.
	LDA #0
	STA <RunningAllTests          ; Clear the "RunningAllTests" variable
	JSR ResetScroll               ; Reset the PPU scroll.
	; Let's draw a menu to render the results!
	JSR DisableRendering
	JSR ClearPage2
	LDA #1
	STA <$10 ; this is "ErrorCode" but since all the tests are over, let's use this to count the number of sprites I'm adding to OAM. Set to 1 by default just to avoid sprite zero hits on the menu.
	LDA #0
	STA <PostAllPassTally
	STA <PostAllTestTally
	JSR ClearNametable	
	JSR SetPPUADDRFromWord
	.byte $20, $E5
	LDA #$D0	; Upper left corner.
	STA $2007
	LDA #$D5	; horizontal bar.
	LDX #0
AREROM_MenuLoop1:
	STA $2007
	INX
	CPX #((EndTableTable - TableTable)/2) ; Compare X with the total page count.
	BNE AREROM_MenuLoop1
	LDA #$D1	; Upper right corner.
	STA $2007
	; And the tallest page has 10 tests, so let's make this ten tiles tall.
	JSR SetPPUADDRFromWord
	.byte $22, $45
	LDA #$D2	; Bottom left corner.
	STA $2007
	LDA #$D5	; horizontal bar.
	LDX #0
AREROM_MenuLoop2:
	STA $2007
	INX
	CPX #((EndTableTable - TableTable)/2) ; Compare X with the total page count.
	BNE AREROM_MenuLoop2
	LDA #$D3	; Bottom right corner.
	STA $2007
	; And set up the horizontal bars.
	LDA #4
	STA $2000	; keep NMI disabled, but set the increment mode to 32 instead of 1.
	JSR SetPPUADDRFromWord
	.byte $21, $05
	LDA #$D4	; horizontal bar.
	LDX #0
AREROM_MenuLoop3:
	STA $2007
	INX
	CPX #10 ; once X = 11, stop.
	BNE AREROM_MenuLoop3
	JSR SetPPUADDRFromWord
	.byte $21, $05+((EndTableTable - TableTable)/2)+1
	LDA #$D4	; horizontal bar.
	LDX #0
AREROM_MenuLoop4:
	STA $2007
	INX
	CPX #10 ; once X = 11, stop.
	BNE AREROM_MenuLoop4
	; Now to print the results of each test in columns corresponding to the pages and indexes into the pages.
	
	LDA #0
	STA <AllTestMenuTotalSkipped
	
AREROM_PageColumnLoop1:
	STY <menuTabXPos
	JSR SetUpSuitePointer         ; Set up the suite pointer.
	JSR LoadSuiteMenuNoRendering  ; Set up the menuHeight, and all the pointers for these tests and results.
	; set the v register to 2106 + Y
	LDA #$21
	STA $2006
	TYA
	CLC
	ADC #06
	STA $2006
	LDX #0
AREROM_PageColumnLoop2:           ; Check results of every test on the page Y.
	; Check for the "print" tests, like "CPU RAM at power on", which isn't really testing anything. These don't need to be counted.
	TXA
	PHA
	ASL A
	TAX
	LDA <suitePointerList+1,X
	STA <$00
	PLA
	TAX
	LDA <$00
	CMP #3	; if the page used to store the results is page 3 instead of page 4, we skip this test.
	BEQ AERROP_Skip
	INC <PostAllTestTally
	STX <Copy_X
	TXA
	ASL A
	TAX
	LDA [suitePointerList,X]	; read the result of test X of page Y
	CMP #$FF					; If the result is $FF, we actually skipped this test.
	BNE AREROM_PageEvaluate
AERROM_SkipTest:
	LDA #$C9					; Print a unique "square" tile to indicate that the test was skipped.
	STA $2007					; ^
	INC <AllTestMenuTotalSkipped
	JMP AERROP_Next
AREROM_PageEvaluate:
	AND #01
	BEQ AREROM_PrintFail ; If the result isn't 1, print the error code
	; and if it passes, print a blue square.
	INC <PostAllPassTally ; also increment the "pass tally"
	LDA #$FE
	STA $2007
	; If this test has multiple pass conditions (SHA/SHS tests, for instance) let's put a sprite here.
	LDA [suitePointerList,X]	; read the result of test X of page Y
	AND #$FE
	BEQ AERROP_Next	; Check if there's an "error code". If not, move on.
	; If so, let's figure out what the coordinates of this test is.
	; X is, humorously going to give us the Y coordinate, and Y is likewise the X coordinate.
	; starting at X coordinate $30, and Y coordinate $40 (-1)
	; Each value of X or Y translates to 8 pixels.
	PHA
	STX <Copy_X2
	LDA <$10	; load the OAM index
	ASL A
	ASL A
	TAX			; transfer to X
	LDA <Copy_X2
	ASL A
	ASL A		; multiply by 4 (X is already multiplied by 2 here)
	CLC
	ADC #$40
	SEC
	SBC #01		; subtract by 1.
	STA $200,X
	; The "error code" will be the pattern.	
	PLA
	LSR A
	LSR A
	STA $201,X
	; The attributes will simply be: palette 1.
	LDA #1
	STA $202,X
	; and the X position
	TYA
	ASL A
	ASL A
	ASL A		; multiply by 8
	CLC
	ADC #$28
	STA $203,X
	INC <$10
	LDX <Copy_X2
	JMP AERROP_Next
AREROM_PrintFail:
	LDA [suitePointerList,X]	; read the result again to get the error code.
	LSR A	; shift error code into A
	LSR A
	ORA #$40	; to make it red in the table, ORA $40
	STA $2007
AERROP_Next:
	LDX <Copy_X
AERROP_Skip:
	INX                           ; increment X until X=MenuHeight.
	CPX <menuHeight
	BNE AREROM_PageColumnLoop2
	                              ; That was all the tests on page Y.
	INY                           ; Y++
	CPY #((EndTableTable - TableTable)/2) ; Compare Y with the total page count.
	BEQ AREROM_PageColumnLoopEnd    ; And loop if there are more pages to run.
	JMP AREROM_PageColumnLoop1
AREROM_PageColumnLoopEnd:
	LDA #0
	STA $2000	; keep NMI disabled, but set the increment mode back to 1.
	; and set up attributes for this table.
	JSR SetPPUADDRFromWord
	.byte $23, $D1
	LDX #0
AERROP_AttributeLoop:
	LDA AERROP_Attributes, X
	STA $2007
	INX
	CPX #22
	BNE AERROP_AttributeLoop

	; Let's print how many tests passed.
	JSR PrintText
	.word $2285
	.byte "Tests passed:", $FF
	;     "Tests passed: xyz / xyz"
	JSR SetPPUADDRFromWord
	.byte $22, $93
	LDA <PostAllPassTally
	JSR PrintByteDecimal_MinDigits
	LDA #$24
	LDX #$33
	STA $2007
	STX $2007
	STA $2007
	LDA <PostAllTestTally
	JSR PrintByteDecimal_MinDigits
	
	LDA <AllTestMenuTotalSkipped
	BEQ AERROP_NoneSkipped
	; Since we skipped some tests, let's print how many tests we skipped.
	JSR PrintText
	.word $22C5
	.byte "Tests skipped:", $FF
	JSR SetPPUADDRFromWord
	.byte $22, $D4
	LDA <AllTestMenuTotalSkipped
	JSR PrintByteDecimal_MinDigits
	
AERROP_NoneSkipped:
	; I'd like to also like to label each of these columns with a page number.
	JSR PrintText
	.word $206E
	.byte "Page", $FF
	JSR PrintText
	.word $20A6
	.byte "1234567891111111111222", $FF
	JSR PrintText
	.word $20CF
	.byte "0123456789012", $FF

	LDA #0
	STA <menuTabXPos

	JSR WaitForVBlank
	JSR SetUpAllTestMenuPalette
	
	LDA #$4C
	STA $700
	LDA #LOW(PressStartToContinue)
	STA $701
	LDA #HIGH(PressStartToContinue)
	STA $702
	
	JSR ResetScroll
	LDA #$08
	STA $2005
	LDA #$00
	STA $2005
	JSR WaitForVBlank
	JSR OAMDMAWithPage2
	JSR EnableRendering
	JSR EnableNMI                 ; And enable the MNI.
	RTS
;;;;;;;

AERROP_Attributes:
	.byte $CC, $FF, $FF, $FF, $FF, $FF, $00, $00
	.byte $CC, $FF, $FF, $FF, $FF, $FF, $00, $00
	.byte $0C, $0F, $0F, $0F, $0F, $0F
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	
PrintTestName:
	TXA
	PHA
	TYA
	PHA
	LDA #1
	STA <dontSetPointer
	LDA <menuCursorYPos
	BNE PTNSkipSuiteName
	LDY #0
	JSR SetUpSuitePointer
	LDA <suitePointer
	STA <AllTestMenuTestNameOffsetLo
	LDA <suitePointer+1
	STA <AllTestMenuTestNameOffsetHi
	JSR SkipSuiteName
PTNSkipSuiteName:
	LDA #$22
	STA <$03
	STA $2006
	LDA #$50
	STA <$04
	LDA <AllTestMenuTestNameOffsetLo
	STA <$0
	LDA <AllTestMenuTestNameOffsetHi
	STA <$1
	LDA #$40
	STA $2006	
	LDA #$24
	LDX #33
PrintTestNameLoop:
	STA $2007
	DEX
	BPL PrintTestNameLoop
	JSR PrintTextCentered
	JSR ResetScroll
	LDA <menuCursorYPos
	CMP <menuHeight
	BEQ SkipFindingNextName
FindNextName:
	JSR AddYToNameOffset
SkipFindingNextName:
	LDA #0
	STA <dontSetPointer
	PLA
	TAY
	PLA
	TAX
	RTS
;;;;;;;

AXYFS_IgnoreStackPointer:
	LDA $593
	CMP #$9B ; SHS *does* update the stack pointer.
	BEQ AXYFS_IgnoreStackPointer_Done
	CMP #$BB ; LAE *does* update the stack pointer.
	BEQ AXYFS_IgnoreStackPointer_Done
	LDA <Test_UnOp_SP
	STA <Test_UnOp_CPS
AXYFS_IgnoreStackPointer_Done:
	RTS

TEST_SHS_Behavior4_9B:
	LDA #$9B
	PHA	
	LDA <RunningAllTests
	BNE TEST_SHA_Behavior4_BNE2
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22D0
	.byte " SHS Behavior 4", $FF
	JSR PrintTextCentered
	.word $2350
	.byte "SHS magic = $", $FF
	TSX
	STX <Copy_SP
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $9B, $F0, $FE ; SHS $FEF0, Y
	LDX <Copy_SP
	TXS
	LDA <$50
	JSR PrintByte
	JSR ResetScrollAndWaitForVBlank
	JMP TEST_SHA_Behavior4

TEST_SHA_Behavior4_93:
	LDA #$93
	PHA	
	LDA <RunningAllTests
TEST_SHA_Behavior4_BNE2:
	BNE TEST_SHA_Behavior4_BNE
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22B0
	.byte " SHA Behavior 4", $FF
	JSR PrintTextCentered
	.word $2330
	.byte "SHA magic = $", $FF
	LDA #$F0
	STA <$60
	LDA #$FE
	STA <$61
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $93, $60; SHA ($0060), Y
	LDA <$50
	JSR PrintByte
	JMP TEST_SHA_Behavior4
	
TEST_SHA_Behavior4_9F:
	LDA #$9F
	PHA ; push the opcode. This just lets me re-use the upcoming code.
	LDA <RunningAllTests
TEST_SHA_Behavior4_BNE:
	BNE TEST_SHA_Behavior4
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22B0
	.byte " SHA Behavior 4", $FF
	
	JSR PrintTextCentered
	.word $2330
	.byte "SHA magic = $", $FF
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $9F, $F0, $FE ; SHA $FEF0, Y
	LDA <$50
	JSR PrintByte
		
TEST_SHA_Behavior4:
	JSR ResetScrollAndWaitForVBlank

	PLA
	JSR TEST_UnOp_Setup; Set the opcode
	; This is the fourth known way that the SHA instruction can behave, and it works like this:
	
	; Stable:
	; Write: A & H
	; Hi = Hi
	
	; Unstable:
	; Write: A & H
	; Hi = Hi & (A | X)
	
	; I'm re-using the code logic here for both SHA and SHS.
	; NOTE: The TEST_RunTest_AddrInitAXYFS subroutine will replace the target stack pointer with the initial stack pointer for SHA instructions.
	
	JSR TEST_RunTest_AddrInitAXYFS
	.word $0555
	.byte $FF
	.byte $FF, $FF, $00, (flag_i), $80
	.word $0555
	.byte $06
	.byte $FF, $FF, $00, (flag_i), $FF
	
	JSR TEST_RunTest_AddrInitAXYFS
	.word $1D60
	.byte $FF
	.byte $03, $FF, $00, (flag_i | flag_z), $5A
	.word $1D60
	.byte $02
	.byte $03, $FF, $00, (flag_i | flag_z), $03
	
	; Now to make the high byte go unstable.
	JSR TEST_RunTest_AddrInitAXYFS
	.word $1F50 ; $1E90 will be the operand.
	.byte $FF
	.byte $F0, $00, $80, (flag_i | flag_c | flag_z | flag_v), $FF
	.word $1050
	.byte $10
	.byte $F0, $00, $80, (flag_i | flag_c | flag_z | flag_v), $00
	
	JSR TEST_RunTest_AddrInitAXYFS
	.word $1F50 ; $1E90 will be the operand.
	.byte $FF
	.byte $50, $AF, $80, (flag_i | flag_c | flag_v), $67
	.word $1050
	.byte $FF
	.byte $50, $AF, $80, (flag_i | flag_c | flag_v), $00
	
	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $8F, $FF, $00, (flag_i), $80
	
	;; END OF TEST ;;
	LDA #17	; Pass, "code 4"
	RTS
;;;;;;;
	
	
TEST_DMA_Plus_2002R:
	
	;;; Test 1 [DMA + $2002]: Verify SLO works. ;;;
	JSR TEST_SLO_1F
	LDX #1
	STX <ErrorCode
	CMP #1
	BNE FAIL_DMA_Plus_2002R
	INC <ErrorCode

	;;; Test 2 [DMA + $2002]: Verify the dummy reads during a DMC DMA can read from $2002 and clear the VBlank flag. ;;;
	
	LDX #0
	JSR WaitForVBlank
	LDA #$00
	STA $4017	; enable the frame counter IRQ, and use the 4-step mode.
	JSR Clockslide_PALFrameIRQ ; Wait for VBlank with the VBlank flag set.
	LDA #0
	.byte $1F
	.word $4015 ; SLO $4015, X
	; if this next cycle is a "put", A = $00. If this next cycle is a "get" A = $80.
	; if the next cycle is a "get", delay by 1 CPU cycle.
	BMI TEST_DMA_Plus_2002R_putSync ; either [(put), (get)] or [(get), (put), (get)]
TEST_DMA_Plus_2002R_putSync:        ; Either way, we are now synced with a put cycle.
	; We are now synced to a "put" cycle.
	; Enable the DMC DMA
	LDA #$10  ; [put] [get]
	STA $4015 ; [put] [get] [put] [get]
	LDA $2002 ; [3] [2] [1] [DMC DMA] [read from $2002, VBlank flag already cleared.]
	BPL TEST_DMA_Plus_2002R_RareBehavior ; Taken = the flag was already cleared (a DMA halting on the $2002 read
	; repeated it: 2A03). Not taken = still set: the 2A07 result, as its load DMA, first tried on the 3rd or 4th cycle
	; after the $4015 write, waits for the next opcode fetch (NESdev forum t=26827, t=24502), i.e. the BPL's, and never
	; repeats the $2002 read. Derived from those sources, not measured on PAL hardware.

	;; END OF TEST ;;
	JSR Test_DMA_Plus_2002_Cleanup
	JSR WaitForVBlank
	LDA <RunningAllTests
	BNE Test_DMA_Plus_2002_Res1
	JSR PrintTextCentered
	.word $2350
	.byte "Load DMA after 2 APU cycles", $FF
	JSR ResetScroll
Test_DMA_Plus_2002_Res1:
	LDA #5	; Success code 1
	RTS
;;;;;;;

FAIL_DMA_Plus_2002R:
	JSR Test_DMA_Plus_2002_Cleanup
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_DMA_Plus_2002R_RareBehavior:
	; Okay, so some very rare CPU revisions actually take an extra APU cycle for load DMAs, so I'm going to allow that behavior as well. Let's check for it.
	JSR WaitForVBlank
	LDA #$00
	STA $4017	; enable the frame counter IRQ, and use the 4-step mode.
	JSR Clockslide_PALFrameIRQ ; Wait for VBlank with the VBlank flag set.
	LDA #0
	.byte $1F
	.word $4015 ; SLO $4015, X
	; if this next cycle is a "put", A = $00. If this next cycle is a "get" A = $80.
	; if the next cycle is a "get", delay by 1 CPU cycle.
	BMI TEST_DMA_Plus_2002R__putSync ; either [(put), (get)] or [(get), (put), (get)]
TEST_DMA_Plus_2002R__putSync:        ; Either way, we are now synced with a put cycle.
	; We are now synced to a "put" cycle.
	; Enable the DMC DMA
	LDA #$10  ; [put] [get]
	STA $4015 ; [put] [get] [put] [get]
	NOP		  ; [5] [4]
	LDA $2002 ; [3] [2] [1] [DMC DMA] [read from $2002, VBlank flag already cleared.]
	BMI FAIL_DMA_Plus_2002R ; If the VBlank flag was set, you fail the test this time for real.
	
	;; END OF TEST ;;
Print_3APUCycleText:
	JSR Test_DMA_Plus_2002_Cleanup
	JSR WaitForVBlank
	LDA <RunningAllTests
	BNE Test_DMA_Plus_2002_Res2
	JSR PrintTextCentered
	.word $2350
	.byte "Load DMA after 3 APU cycles", $FF
	JSR ResetScroll
Test_DMA_Plus_2002_Res2:	
	LDA #9 ; Success code 2
	RTS
;;;;;;;


Test_DMA_Plus_2002_Cleanup:
	LDA #0
	STA $4015
	LDA #$40
	STA $4017
	RTS
;;;;;;;
	

FAIL2_SuddenlyResizeSprite:
	JMP TEST_Fail
	
TEST_Rendering2007Read:
	
	;;; Test 1 [$2007 Read w/ Rendering]: verify sprite zero hits real quick... ;;;

	JSR VerifySpriteZeroHits
	BEQ FAIL2_SuddenlyResizeSprite
	INC <ErrorCode
	
	;;; Test 2 [$2007 Read w/ Rendering]: If you read from address $2007 while rendering is enabled, the v register gets incremented in an unusual way. Let's test for it! ;;;

	; The previous test already sets up the nametable for this next test.
	; Let's begin by setting sprite zero to be one scanline higher up than it was in the previous test.
	JSR SetUpSpriteZero        ; Prepare sprite zero with the following values:
	.byte $05, $C0, $03, $08   ; Single dot on scanline 4, X = 08
	
	JSR PrintCHR
	.word $2C01                ; Single dot to overlap the sprite. (we're intentionally hitting this one)
	.byte $E4, $FF             ; This will trigger the sprite zero hit.	
	JSR ResetScroll_2C00
	
	JSR WaitForVBlank
	LDA #0
	STA $2003 ; start the DMA at OAM[0]
	JSR OAMDMAWithPage2
	JSR EnableRendering ; do not rely on the prerequisite leaving rendering enabled
	
	; We don't need the most precise timing for this.
	; Simply read from $2007 at some point on a visible scanline.
	
	JSR Clockslide_9000 ; PAL: 2000 cycles is still inside the 70-line VBlank
	LDA $2007 ; this is what we are testing for. What happens to v?
	; The correct answer is, v+= $1001
	LDA $2002
	AND #$40
	BEQ FAIL2_SuddenlyResizeSprite ; if the was no sprite zero hit, fail the test.
	
	;; END OF TEST ;;

	LDA #1
	RTS
;;;;;;;

FAIL_BranchDummyRead:
	JMP TEST_Fail

TEST_BranchDummyRead:

	JSR DisableRendering

	;;; Test 1 [Branch Dummy Reads]: (prerequisite) verify RAM mirroring. ;;;
	LDA #$60
	STA $7F2  ; Write to $7F2.
	LDX $1FF2 ; Read from $1FF2, a mirror of $7F2.
	CPX #$60
	BNE FAIL_BranchDummyRead ; If the mirror doesn't match, abort!
	INC <ErrorCode
	
	;;; Test 2 [Branch Dummy Reads]: (prerequisite) verify ppu IO open bus. ;;;
	LDA #$90
	STA $2002 ; Write to PPU IO bus.
	LDX $2000 ; Read from ppu IO bus.
	CPX #$90
	BNE FAIL_BranchDummyRead ; If the value read doesn't match the value written, abort!
	LDA $2002 ; verify that bits 0 through 4 are open bus:
	AND #$1F ; Mask away bits 5, 6, and 7.
	CMP #$10
	BNE FAIL_BranchDummyRead ; If the value read doesn't match the expected value, abort!
	LDA #$5A
	JSR SetPPUReadBufferToA
	LDA $2007
	TXA ; just make sure A isn't the correct answer before we read from $2000. I can imagine an incredibly wrong implementation of open bus simply not changing A, and somehow making it this far.
	LDA $2000
	CMP #$5A
	BNE FAIL_BranchDummyRead ; If the value read doesn't match the expected value, abort!
	INC <ErrorCode

	;;; Test 3 [Branch Dummy Reads]: (prerequisite) verify address $2004 behavior. ;;;
	; Pre revision G PPUs behave differently, so we want this to work on either case.
	; Let's just make sure we read either OAMDATA or PPU IO Open bus.
	LDA #$60
	STA $200
	
	JSR WaitForVBlank
	JSR Clockslide_PALFrame ; Set the vblank flag. (This will hopefully persist until we JSR to $2000 in the next test.
	
	JSR OAMDMAWithPage2 ; OAM DMA
	STA $2002	
	LDX $2004 ; OAM[0] = $60.
	CMP #2
	BEQ BranchDummyRead_RevE
	CPX #$60
FAIL_BranchDummyRead_BNE:
	BNE FAIL_BranchDummyRead ; If OAMDATA isn't working, abort!
BranchDummyRead_RevE:
	INC <ErrorCode
	
	;;; Test 4 [Branch Dummy Reads]: Verify the first dummy read on a branch ;;;
	; Branches work like this:
	; 1. [Read opcode]
	; 2. [read operand]
	; 3. [dummy read the byte after the operand]
	; 4. [dummy read the temporary location of the PC before correcting the high byte]
	
	; Let's begin by verifying the dummy read on cycle 3.
	; Verifying this dummy read is harder than verifying the dummy read on cycle 4.
	; If cycle 3 was on PPUSTATUS, then the following cycle is forced to read from PPUSTATUS.
	; - Since both the opcode and operand are using the ppu bus, they must match. Since all branch opcodes end in $0, the destination from the branch will end up on $xxx2.
	; - If branching backwards, $20x2 will be read on cycle 4.
	; - If branching forwards, $20x2 will be the opcode for the next instruction.
	; Luckily, the PPU runs faster than the CPU, so we know for sure that the second consecutive read will have the vblank flag cleared. (But only if the dummy read exists.)
	; So failing this test will run opcode %1--10000, while passing would run %0--10000.
	; If we leave the sprite overflow and sprite zero flags cleared, then we form a BPL on pass, BCC on fail.
	; BPL will take us to $2024, reading $60 from OAMDATA (RTS)
	; BCC will take us to $1FA4...

	LDA #$E6 ; INC Zero Page opcode
	STA $1FA4
	LDA #$50
	STA $1FA5
	LDA #$60
	STA $1FA6 ; A=60. RTS
	; $1FA4 now reads: INC <$50, RTS

	
	JSR SetPPUReadBufferToA ; For a revision E or earlier ppu.
	
	LDA #$10
	STA $2002; update PPU bus with $10 (opcode for BPL)
	JSR $2000; jump to PPU registers.
	; $2000: (opcode: $10 = BPL)
	; $2001: (operand: $10. BPL $2012)
	; $2002: (Dummy read. Update PCL. PC = $2012. End of instruction.)
	; $2012: (BPL $2024)
	; $2024: (opcode: $60 = RTS)
	
	; Or, if this is a pre revision G PPU...
	; $2000: (opcode: $10 = BPL)
	; $2001: (operand: $10. BPL $2012)
	; $2002: (Dummy read. Update PCL. PC = $2012. End of instruction.)
	; $2012: (BPL $2024)
	; $2024: (BPL $2036)
	; $2036: (BPL $2098) ($2037 = $60)
	; $2098: (opcode: $60 = RTS)	
	
	LDA <$50 ; If you failed the test, then you would have executed INC <$50 at $1FA4.
	BNE FAIL_BranchDummyRead_BNE
	INC <ErrorCode
	
	;;; Test 5 [Branch Dummy Reads]: Verify the second dummy read on a branch ;;;
	; This one is much easier to test for. Simply BCC at $1FFF to $1FF2.

	; There is already an RTS opcode at $1FF2, from error code 1.
	
	JSR WaitForVBlank
	JSR Clockslide_PALFrame ; Set the vblank flag.
	LDA #$90
	STA $1FFF ; Set address $1FFF to be the opcode for BCC.
	LDA #$F1
	STA $2002 ; Set the PPU IO bus to $0F. (The operand needed for the BCC.)
	CLC ; We're about to run a BCC instruction at $1FFF, so let's clear the carry flag.
	JSR $1FFF ; Jump to $1FFF to run the test.
	; $1FFF: (opcode: $90 = BCC)
	; $2000: (operand: $F1. BCC $1FF2)
	; $2001: (Dummy Read. Update PCL. PC = $20F2.)
	; $20F2: (Dummy Read. Update PCH. PC = $1FF2. End of instruction.)
	; $1FF2: (opcode: $60 = RTS)
	LDA $2002 ; read PPUSTATUS
	AND #$80  ; Keep only the vblank flag.
	BNE FAIL_BranchDummyRead_BNE ; If the vblank flag was still set, fail the test.
	;; END OF TEST ;;

	LDA #1
	RTS
;;;;;;;

TEST_2002FlagTiming:
	; STATUS: DERIVED [2A07][2C07] The VBlank, sprite zero hit and sprite overflow flags are all cleared on dot 1 of the
	; pre-render line. A read of $2002 latches the VBlank flag when M2 rises but takes the sprite flags when M2 falls.
	; NESdev "CPU pinout": M2's duty cycle is 19/32 on the 2A07, so the sprite flags are read 19/32 of a CPU cycle
	; (1.9 dots) after the VBlank flag is latched (2A03E/G/H: 15/24, 1.875 dots). A read that straddles the clearing
	; dot therefore returns the VBlank flag still set and both sprite flags clear: $80.
	; The 2C02 version steps its read one dot at a time with a dot-exact sync. On PAL a read can only be moved 1.6 dots
	; at a time (one 33248-cycle frame of VblSync_Plus_A per sample), so this version takes 8 samples, 1.6 dots apart,
	; across the clearing dot (the timing of [VBlank end], one frame after the sync), with rendering enabled for the
	; frame before so that the sprite flags are set.
	;;; Test 1 [$2002 flag timing]: Verify the timing in which the sprite zero and sprite overflow flags are cleared. ;;;
	; Each sample is $2002 & $E0. Key: the first is $E0 (all three flags set), the last is $00, they go $E0 ... $80 ...
	; $00 and never back, and $80 appears once or twice (a 1.9-dot window sampled every 1.6 dots cannot be missed).
	LDX #0
TEST_2002FT_SpriteLoop:
	JSR InitializeSpriteX
	.byte $80, $FE, $00, $80
	INX
	BNE TEST_2002FT_SpriteLoop
	DEC $200 ; make sprite zero one scanline earlier.
	; okay, now every object will be drawn at Y=$80, X=$80 (sprite zero at Y=$7F): sprite zero hit and sprite overflow.
	JSR DisableRendering
	JSR ClearNametable2_With24 ; Nametable 2 is polluted from other tests. Since it gets drawn during this test, let's clear it first.
	JSR PrintCHR
	.word $2E10
	.byte $FE, $FF
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDX #0
TEST_2002FT_Loop:
	LDA #0
	STA $2003
	LDA #2
	STA $4014 ; OAM DMA before the sync: a DMA takes 513 or 514 cycles by the APU's get/put parity, which would make
	          ; the step between samples uneven if it came after the sync.
	TXA
	PHA
	JSR VblSync_Plus_A ; rendering is off: sync to the start of VBlank, 1.6 dots later per sample
	LDA #$18
	STA $2001 ; render the next frame, so its sprite zero hit and sprite overflow flags are set
	JSR ClockslideFromWord
	.word 40670 ; the read below lands across dot 1 of the next pre-render line (scanline 311). Measured: E0 E0 E0 E0 E0 80 00 00
	LDA $2002
	AND #$E0
	TAY
	JSR DisableRendering
	PLA
	TAX
	TYA
	STA <$50,X
	INX
	CPX #8
	BNE TEST_2002FT_Loop
	; Check the key.
	LDA <$50
	CMP #$E0
	BNE TEST_2002FT_Fail
	LDA <$57
	BNE TEST_2002FT_Fail
	LDA #0
	STA <$5C ; previous rank
	STA <$5D ; number of $80 samples
	LDX #0
TEST_2002FT_Check:
	LDA <$50,X
	LDY #0
	CMP #$E0
	BEQ TEST_2002FT_Ranked
	INY
	CMP #$80
	BEQ TEST_2002FT_Is80
	INY
	CMP #$00
	BEQ TEST_2002FT_Ranked
	BNE TEST_2002FT_Fail ; any other combination of flags
TEST_2002FT_Is80:
	INC <$5D
TEST_2002FT_Ranked:
	CPY <$5C
	BCC TEST_2002FT_Fail ; went back
	STY <$5C
	INX
	CPX #8
	BNE TEST_2002FT_Check
	LDA <$5D
	BEQ TEST_2002FT_Fail ; the VBlank flag was never seen set with the sprite flags clear
	CMP #3
	BCS TEST_2002FT_Fail
	;; END OF TEST ;;
	LDA #1
	RTS
TEST_2002FT_Fail:
	JMP TEST_Fail
;;;;;;;

Print_PreRevGBehavior:
	JSR DisableRendering
	JSR PrintTextCentered
	.word $2350
	.byte "Pre revision G PPU behavior!", $FF
	RTS
;;;;;;;

Stress2004_RevE:
	; Revision G PPUs added the ability to read from Palette RAM.
	; In order to prevent Pre-Revision-G PPUs from "failing" the test, we exit early.
	; However, we will write on screen that we didn't actually finish the test.
	LDA <RunningAllTests
	BNE Stress2004_RevE_SkipMSG
	JSR Print_PreRevGBehavior
	JSR PrintTextCentered
	.word $2370
	.byte "This test requires rev G / later", $FF
Stress2004_RevE_SkipMSG:
	LDA #$FF ; Mark this test to be skipped.
	RTS
;;;;;;;

TEST_2004_Stress:
	; STATUS: DERIVED [2C07] (sampling stage)
	;;; Test 1 [$2004 Stress Test]: Pre test ;;;
	LDA <result_VblankSync_PreTest
	BNE T24_PreOK
	JMP TEST_Fail
T24_PreOK:
	INC <ErrorCode
	LDX #1
	LDA #5
	STX $2003
	STA $2004
	STX $2003
	LDA $2004
	CMP #1
	BNE T24_NotRevE
	JMP Stress2004_RevE
T24_NotRevE:
	JSR DisableRendering
	JSR ClearNametable2_With24
	LDY #$FF
	LDX #0
	TYA
T24_Prep:
	STA $200, X
	DEY
	TYA
	INX
	BNE T24_Prep
	JSR T24_Run
	;;; Test 2 [$2004 Stress Test]: With OAM set to $FF, $FE ... $00, the $2004 reads match the 2C02 version's key. ;;;
	JSR STR_Eval
	.word KEY_2004_1
	.byte 220, 80, 93, 150, 0 ; 220 samples, o = 16 to 28 (measured: 22), at least 150 checks, every dot
	CMP #1
	BEQ T24_Pass1
	JMP TEST_Fail
T24_Pass1:
	INC <ErrorCode
	;;; Test 3 [$2004 Stress Test]: With OAM set to Test_2004_Stress_OAM, then 0, 1, 2 ..., the reads match the second key. ;;;
	LDX #0
T24_Prep2:
	LDA Test_2004_Stress_OAM, X
	STA $200, X
	INX
	CPX #32
	BNE T24_Prep2
	LDY #0
T24_Prep3:
	TYA
	STA $200, X
	INY
	INX
	BNE T24_Prep3
	JSR T24_Run
	JSR STR_Eval
	.word KEY_2004_2
	.byte 220, 80, 93, 150, 0
	CMP #1
	BEQ T24_Pass2
	JMP TEST_Fail
T24_Pass2:
	LDA #1
	RTS


TEST_2007_Stress:
	; STATUS: DERIVED [2C07] The 2C02 version reads $2007 once per frame while the PPU renders scanline 0, one dot later
	; each frame (341 samples), and compares the read buffer on every odd dot with a key; the even dots are unstable.
	; A PAL frame is 33247.5 CPU cycles, so a loop of whole cycles moves the read 1.6 dots per frame: 214 samples cover
	; the scanline, landing on 5 of every 8 dots in one of 5 patterns. TEST_2007PAL_Eval finds the pattern and offset
	; and checks the samples against the 2C02 version's key. Negative control: with rendering left off
	; the reads only return VRAM and the test fails at 2. Pending hardware.
	;;; Test 1 [$2007 Stress Test]: Pre test to make sure the emulator won't crash  ;;;
	LDA <result_VblankSync_PreTest
	BNE TEST_2007PAL_PreOK
	JMP TEST_Fail
TEST_2007PAL_PreOK:
	INC <ErrorCode
	JSR DisableRendering
	JSR ClearNametable2
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDX #0
	LDY #4
TEST_2007PAL_Fill:
	STX $2007
	INX
	BNE TEST_2007PAL_Fill
	DEY
	BNE TEST_2007PAL_Fill
	JSR Sync_ToLine0Dot1
	LDX #0
	STX $2001
	JSR ClockslideFromWord
	.word 32999
	JSR Clockslide_PALFrame
	JSR Clockslide_PALFrame ; the first sampled read lands on dot 1 of scanline 0
TEST_2007PAL_Loop:
	; One pass is 33248 CPU cycles: half a cycle (1.6 dots) more than a PAL frame.
	LDA #$18
	STA $2006
	LDA #$00
	STA $2006
	STA $2001 ; v = $1800, rendering off
	JSR Clockslide_100
	LDA #$08
	STA $2001 ; background rendering on, 87 CPU cycles before the read (the end of the pre-render line)
	JSR Clockslide_50
	JSR Clockslide_31
	LDA $2007 ; the sampled read
	LDA #0
	STA $2001 ; rendering off
	LDA $2007 ; the read buffer
	STA $500,X
	INX
	CPX #214
	BEQ TEST_2007PAL_Done
	JSR ClockslideFromWord
	.word 33017
	JMP TEST_2007PAL_Loop
TEST_2007PAL_Done:
	;;; Test 2 [$2007 Stress Test]: The buffer values match the 2C02 version's key on the dots the reads landed on. ;;;
	JSR STR_Eval
	.word KEY_2007
	.byte 214, 30, 43, 32, 1 ; 214 samples, o = -34 to -22 (measured: -28), at least 32 checks, odd dots only
	CMP #1
	BEQ TEST_2007PAL_Pass
	JMP TEST_Fail
TEST_2007PAL_Pass:
	LDA #1
	RTS

FAIL_StaleSpriteShiftRegs:
	JMP TEST_Fail



WaitForFrameCounterIRQFlag:
	LDA #$00               ;
	STA $4017              ; Reset the APU Frame Counter
	JSR Clockslide_PALFrameIRQ ; Wait for the PAL 2A07 4-step IRQ flag.
	RTS                    ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

FAIL_DMALandingOnWrite1:             ;
	JMP FAIL_AndDisableAudioChannels ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	;;; DMA Landing on Write ;;;
	;;;;;;;;;;;;;;;;;;;;;;;;;;;;	
TEST_DMALandingOnWrite:
	;;; Test 1 [DMA Landing on Write]: Open bus should not always read 00 ;;;
	LDA $4000                        ;
	BEQ FAIL_DMALandingOnWrite1      ;
	INC <ErrorCode                   ;

	;;; Test 2 [DMA Landing on Write]: The DMC DMA can update the data bus when reading from open bus ;;;
	JSR TEST_DMA_Plus_OpenBus        ;
	LDX #2                           ; The DMA Plus Open Bus test increments the error code, so let's fix it real quick.
	STX <ErrorCode                   ;
	CMP #1                           ;
	BNE FAIL_DMALandingOnWrite1      ;
	INC <ErrorCode                   ;

	;;; Test 3 [DMA Landing on Write]: (2A07) A DMA requested on a write cycle waits for the next opcode fetch ;;;
	; 2A07 form (the 2A03 form, "the write delays the halt by one cycle and the DMA then takes 3", does not apply:
	; a 2A07 DMA does not halt on any cycle but an opcode fetch). A DMA requested on the first write cycle of JSR $4000
	; (c3) must wait through the second write and the operand read and land on the $4000 opcode fetch.
	LDA #LOW(TEST_DLW_T3Ret)
	LDX #HIGH(TEST_DLW_T3Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DLW_T3Ret
	JSR DMASync_50CyclesRemaining     ; the DMA's request point R is 50 cycles after this returns
	LDA #$9D                          ; 2
	PHA                               ; 3  high byte of the RTI target (see TEST_DLW_JSRProbe)
	JSR Clockslide_39                ; 39
	JMP TEST_DLW_JSRProbe             ; 3  JSR $4000 fetched at 5 + 39 + 3 = 47: R = 50 falls on its c3
TEST_DLW_T3Ret:
	LDA <$50
	CMP #1
	BNE FAIL_DMALandingOnWrite1
	INC <ErrorCode                   ;
	;;; Test 4 [DMA Landing on Write]: (2A07) ...also when requested on the second of two write cycles ;;;
	; 2A07 form: a DMA requested on the second of two consecutive write cycles (JSR's c4) also waits for the
	; $4000 opcode fetch. (The 2A03 subject of this test, a 3-cycle DMA after a delayed halt, needs a DMA length
	; measurement that the 2A07 tests do not have yet.)
	LDA #LOW(TEST_DLW_T4Ret)
	LDX #HIGH(TEST_DLW_T4Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DLW_T4Ret
	JSR DMASync_50CyclesRemaining     ; the DMA's request point R is 50 cycles after this returns
	LDA #$9D                          ; 2
	PHA                               ; 3  high byte of the RTI target (see TEST_DLW_JSRProbe)
	JSR Clockslide_38                ; 38
	JMP TEST_DLW_JSRProbe             ; 3  JSR $4000 fetched at 5 + 38 + 3 = 46: R = 50 falls on its c4
TEST_DLW_T4Ret:
	LDA <$50
	CMP #1
	BNE FAIL_DMALandingOnWrite1
	INC <ErrorCode                   ;
	;;; Test 5 [DMA Landing on Write]: (2A07) ...and on a read that is not an opcode fetch; not when requested on one ;;;
	; 2A07 form: the DMA does not halt on a READ that is not an opcode fetch either: requested on JSR's dummy
	; stack read (c2) it still lands on the $4000 fetch. Control: requested on the JSR's own opcode fetch (c0) it
	; halts right there, so the $4000 fetch sees no DMA (a probe that always fired would pass the cases above).
	LDA #LOW(TEST_DLW_T5Ret)
	LDX #HIGH(TEST_DLW_T5Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DLW_T5Ret
	JSR DMASync_50CyclesRemaining     ; the DMA's request point R is 50 cycles after this returns
	LDA #$9D                          ; 2
	PHA                               ; 3  high byte of the RTI target (see TEST_DLW_JSRProbe)
	JSR Clockslide_40                ; 40
	JMP TEST_DLW_JSRProbe             ; 3  JSR $4000 fetched at 5 + 40 + 3 = 48: R = 50 falls on its c2
TEST_DLW_T5Ret:
	LDA <$50
	CMP #1
	BNE FAIL_DMALandingOnWrite1
	LDA #LOW(TEST_DLW_T5bRet)
	LDX #HIGH(TEST_DLW_T5bRet)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DLW_T5bRet
	JSR DMASync_50CyclesRemaining     ; the DMA's request point R is 50 cycles after this returns
	LDA #$9D                          ; 2
	PHA                               ; 3  high byte of the RTI target (see TEST_DLW_JSRProbe)
	JSR Clockslide_42                ; 42
	JMP TEST_DLW_JSRProbe             ; 3  JSR $4000 fetched at 5 + 42 + 3 = 50: R = 50 falls on its c0
TEST_DLW_T5bRet:
	LDA <$50
	CMP #0
	BNE FAIL_DMALandingOnWrite1
	INC <ErrorCode                   ;
	;;; Test 6 [DMA Landing on Write]: (2A07) A load DMA's first halt attempt is in the 2nd APU cycle after the $4015 write ;;;
	; 2A07 form. A load DMA is scheduled to halt the CPU on the get cycle of the 2nd APU cycle after the $4015
	; write, i.e. 3 or 4 CPU cycles after it; if that cycle cannot halt (on a 2A07: any cycle that is not an opcode
	; fetch) it retries on each following cycle (NESdev "DMA"; NESdev forum "DMC DMA incorrect timing?", t=26827;
	; "DPCM + $2007 reads", t=24502: "you'll get it on the 3rd or 4th following cycle"). OAM DMA leaves the CPU on a
	; get cycle (the original test's alignment), so with LDA zp before it the write falls on a GET: first attempt on
	; the 4th cycle after the write. Layout after the write: NOP (fetch +1), JMP $4000 (fetch +3), $4000 fetch at +6.
	; The +3 fetch is before the attempt, so the DMA lands on the $4000 fetch: probe hit.
	JSR TEST_DLW_LoadPrep             ; DMC off, rate $F, 1-byte $00 sample at $FFC0, buffer emptied
	LDA #LOW(TEST_DLW_T6Ret)
	LDX #HIGH(TEST_DLW_T6Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DLW_T6Ret
	LDA #HIGH(TEST_DLW_T6Ret)
	PHA
	LDA #LOW(TEST_DLW_T6Ret)
	PHA
	PHP                               ; the probe's RTI frame
	LDA #2                            ; OAM DMA from page 2
	STA $4014                         ; the CPU resumes on a get cycle
	LDA <$00                          ; 3  (get put get)
	LDA #$10                          ; 2
	STA $4015                         ; 4  enable the DMC: load DMA (buffer empty)
	NOP                               ; fetch +1
	JMP $4000                         ; fetch +3; $4000 fetched at +6
TEST_DLW_T6Ret:
	LDA <$50
	CMP #1
	BEQ TEST_DLW_T6Ret_OK
	JMP FAIL_DMALandingOnWrite1
TEST_DLW_T6Ret_OK:
	INC <ErrorCode
	;;; Test 7 [DMA Landing on Write]: (2A07) ...which is the 3rd cycle after a write on a put cycle ;;;
	; 2A07 form. One cycle later (LDA abs instead of LDA zp) the write falls on a PUT: first attempt on the 3rd
	; cycle after the write, which is the JMP's opcode fetch in the same layout: the DMA lands there and the $4000
	; fetch sees nothing (expected 0). Test 9 shows the DMA does happen with this parity.
	JSR TEST_DLW_LoadPrep             ; DMC off, rate $F, 1-byte $00 sample at $FFC0, buffer emptied
	LDA #LOW(TEST_DLW_T7Ret)
	LDX #HIGH(TEST_DLW_T7Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DLW_T7Ret
	LDA #HIGH(TEST_DLW_T7Ret)
	PHA
	LDA #LOW(TEST_DLW_T7Ret)
	PHA
	PHP                               ; the probe's RTI frame
	LDA #2                            ; OAM DMA from page 2
	STA $4014                         ; the CPU resumes on a get cycle
	LDA $0000                         ; 4  (one cycle more than test 6)
	LDA #$10                          ; 2
	STA $4015                         ; 4  enable the DMC: load DMA (buffer empty)
	NOP                               ; fetch +1
	JMP $4000                         ; fetch +3 (the DMA lands here); $4000 fetched at +6
TEST_DLW_T7Ret:
	LDA <$50
	CMP #0
	BEQ TEST_DLW_T7Ret_OK
	JMP FAIL_DMALandingOnWrite1
TEST_DLW_T7Ret_OK:
	INC <ErrorCode
	;;; Test 8 [DMA Landing on Write]: Load DMAs also cannot land on write cycles ;;;
	LDA #0                           ;
	STA $4015                        ; disable DMC
	JSR WaitForFrameCounterIRQFlag   ;
	LDA #$10                         ;
	STA $4014                        ; Trigger an OAM DMA to align with a Get cycle next.
	LDA $00                          ; delay 3 cycles to sync with put cycle.
	STA $4015                        ; [Opcode (put)] [Operand (get)] [Operand (put)] [Write (get)]
	STA $4015                        ; [Opcode (put)] [Operand (get)] [Operand (put)] {Write (get)} This delays the DMA by a cycle, and does NOT read from $4015
	LDA $4015                        ;
	AND #$40                         ; Filter for the Frame Counter IRQ Flag
	BEQ FAIL_DMALandingOnWrite       ;
	INC <ErrorCode                   ;

	;;; Test 9 [DMA Landing on Write]: (2A07) ...and lands on the first opcode fetch after it ;;;
	; 2A07 form (the 2A03 subject, "a load DMA delayed by a write takes 4 cycles", needs a DMA length measurement).
	; Write on a PUT as in test 7, but JMP $4000 right after the write: fetch +1, $4000 fetched at +4. The first
	; attempt on +3 is an operand read, so the DMA waits for the $4000 fetch: probe hit.
	JSR TEST_DLW_LoadPrep             ; DMC off, rate $F, 1-byte $00 sample at $FFC0, buffer emptied
	LDA #LOW(TEST_DLW_T9Ret)
	LDX #HIGH(TEST_DLW_T9Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DLW_T9Ret
	LDA #HIGH(TEST_DLW_T9Ret)
	PHA
	LDA #LOW(TEST_DLW_T9Ret)
	PHA
	PHP                               ; the probe's RTI frame
	LDA #2                            ; OAM DMA from page 2
	STA $4014                         ; the CPU resumes on a get cycle
	LDA $0000                         ; 4
	LDA #$10                          ; 2
	STA $4015                         ; 4  enable the DMC: load DMA (buffer empty)
	JMP $4000                         ; fetch +1; $4000 fetched at +4
TEST_DLW_T9Ret:
	LDA <$50
	CMP #1
	BEQ TEST_DLW_T9Ret_OK
	JMP FAIL_DMALandingOnWrite1
TEST_DLW_T9Ret_OK:
	;; End Of Test ;;                ;
	LDA #5                           ;
	RTS                              ;	
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
FAIL_DMALandingOnWrite:              ;
	JMP FAIL_AndDisableAudioChannels ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

FAIL_DMCPlaybackRate:               ;
	JMP TEST_Fail                   ;
	                                ;
TEST_DMCPlaybackRate:               ;
	;;; Test 1 [DMC Playback Rate]: Do you pass DMA + Open Bus? ;;;
	JSR TEST_DMA_Plus_OpenBus       ;
	LDX #1                          ; The DMA Plus Open Bus test increments the error code, so let's fix it real quick.
	STX <ErrorCode                  ;
	CMP #1                          ;
	BNE FAIL_DMCPlaybackRate        ;
	INC <ErrorCode                  ;
	LDX #0                          ; Reset X for the upcoming loop.
	                                ;
	LDA #$20                        ; This upcoming loop needs to stall for very precise amounts of CPU cycles.
	STA <$60                        ; Unfortunately, this precise amount needs to be different in each iteration of this loop.
	LDA #LOW(ClockslideFromWord)    ; My solution involves a `JSR ClockslideFromWord` in RAM, and I can just change the arguments in the loop.
	STA <$61                        ;
	LDA #HIGH(ClockslideFromWord)   ;
	STA <$62                        ;
	LDA #$60                        ;
	STA <$65                        ;
	                                ;
	;;; Test 2 through H [DMC Playback Rate]: Does the DMC take the correct number of APU cycles between DMA's when the sample rate is set to the value of the X register? ;;;
	                                ;
TEST_DMCPlaybackRate_Loop:          ;
	LDA DMCPR_DelayLO, X            ;
	STA <$63                        ; The low byte of the clockslide
	LDA DMCPR_DelayHI, X            ;
	STA <$64                        ; the high byte of the clockslide
	TXA                             ; Install the open-bus opcode probe (not timed)
	PHA
	LDA #LOW(TEST_DMCPlaybackRate_Ret)
	LDX #HIGH(TEST_DMCPlaybackRate_Ret)
	JSR TEST_OBProbe_Install
	PLA
	TAX
	JSR DMASync_50CyclesRemaining   ;
	TXA                             ;
	ORA #$40                        ;
	STA $4010                       ; By this point, the DMC timer/lfsr has been refreshed already, so the write to $4010 won't affect the upcoming DMA.
	JSR Clockslide_42               ;
	; DMA happens here.
	JSR $0060                       ; This leads to a ClockslideFromWord, which will stall for precisely the amount determined by DMCPR_DelayHI and DMCPR_DelayLO.
	; 2A07 form. The DMA requested at R (cycle 50 after DMASync_50CyclesRemaining) lands on the JSR $0060 just
	; above, whose opcode fetch is exactly R, and steals 4 cycles (the same phase as the sync's own detection: R2 of the
	; 2A07 DMA rules). The next request is R + P (P = one byte at the rate just written: 8 * the PAL table). The probe
	; below puts its $4000 opcode fetch on R + P: the JSR $0060 starts at wall R + 4 and takes delay + 12 cycles, the probe
	; 16 more, so delay = P - 32 (DMCPR_Overhead = 32). Traced with the 2A07 DMA behavior: with 39 the $4000 fetch came
	; 7 cycles early, which is how the earlier miscount (the 4 stolen cycles counted twice) was found.
	LDA #HIGH(TEST_DMCPlaybackRate_Ret) ; 2
	PHA                             ; 3
	LDA #LOW(TEST_DMCPlaybackRate_Ret) ; 2
	PHA                             ; 3
	PHP                             ; 3
	JMP $4000                       ; 3: the opcode fetch at $4000 is on R + P
TEST_DMCPlaybackRate_Ret:
	LDA <$50
	BEQ FAIL_DMCPlaybackRate        ; the DMA did not land on the $4000 fetch
	                                ;
	INC <ErrorCode                  ;
	                                ;
	INX                             ;
	CPX #$10                        ;
	BNE TEST_DMCPlaybackRate_Loop   ;
	                                ;
	LDA #1                          ;
	RTS                             ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
DMCPR_Overhead = 32                 ; 19 + 13. The 19 is 12 (JSR $0060 and back) + 4 (the DMA at R) + 3 (an LDA abs up to its read);
									 ; the probe needs 16 cycles up to its $4000 fetch instead of those 3: 13 more.
DMCPR_DelayHI:                      ;
	.byte HIGH(3184-DMCPR_Overhead) ;
	.byte HIGH(2832-DMCPR_Overhead) ;
	.byte HIGH(2528-DMCPR_Overhead) ;
	.byte HIGH(2384-DMCPR_Overhead) ;
	.byte HIGH(2208-DMCPR_Overhead) ;
	.byte HIGH(1888-DMCPR_Overhead) ;
	.byte HIGH(1680-DMCPR_Overhead) ;
	.byte HIGH(1584-DMCPR_Overhead) ;
	.byte HIGH(1408-DMCPR_Overhead) ;
	.byte HIGH(1184-DMCPR_Overhead) ;
	.byte HIGH(1056-DMCPR_Overhead) ;
	.byte HIGH(944-DMCPR_Overhead) ;
	.byte HIGH(784-DMCPR_Overhead)  ;
	.byte HIGH(624-DMCPR_Overhead)  ;
	.byte HIGH(528-DMCPR_Overhead)  ;
	.byte HIGH(400-DMCPR_Overhead)  ;
	                                ;
DMCPR_DelayLO:                      ;
	.byte LOW(3184-DMCPR_Overhead)  ;
	.byte LOW(2832-DMCPR_Overhead)  ;
	.byte LOW(2528-DMCPR_Overhead)  ;
	.byte LOW(2384-DMCPR_Overhead)  ;
	.byte LOW(2208-DMCPR_Overhead)  ;
	.byte LOW(1888-DMCPR_Overhead)  ;
	.byte LOW(1680-DMCPR_Overhead)  ;
	.byte LOW(1584-DMCPR_Overhead)  ;
	.byte LOW(1408-DMCPR_Overhead)  ;
	.byte LOW(1184-DMCPR_Overhead)  ;
	.byte LOW(1056-DMCPR_Overhead)  ;
	.byte LOW(944-DMCPR_Overhead)  ;
	.byte LOW(784-DMCPR_Overhead)   ;
	.byte LOW(624-DMCPR_Overhead)   ;
	.byte LOW(528-DMCPR_Overhead)   ;
	.byte LOW(400-DMCPR_Overhead)   ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;



;;;;;;;;;;;;;;;;;;;;;;;;;;;;


ClearNametable2_WithF0:
	LDA #$F0
	.byte $2C ; BIT Absolute. (skip the LDA #24)
ClearNametable2_With24:
	LDA #$24
	.byte $2C ; BIT Absolute. (skip the LDA #0)
ClearNametable2:
	LDA #0
ClearNametable2_s:
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDY #$C0
	LDX #4
TEST_RMW2007_ClearNametable2Loop:
	STA $2007
	DEY
	BNE TEST_RMW2007_ClearNametable2Loop
	DEX
	BNE TEST_RMW2007_ClearNametable2Loop
	LDA #$FF
	LDY #$40
	TEST_RMW2007_ClearNT2Loop2:
	STA $2007
	DEY
	BNE TEST_RMW2007_ClearNT2Loop2	
	RTS
;;;;;;;

	; TEST A OF THE I-FLAG LATENCY TEST, REBUILT FOR THE 2A07.
	; Question: does a taken branch (no page crossing) poll for interrupts before its 3rd cycle? It should not: it polls
	; only where a 2-cycle instruction does, one cycle earlier than a normal 3-cycle instruction (NESdev "CPU
	; interrupts", branch instructions).
	; Why not the DMC IRQ: on a 2A07 a DMC IRQ is raised by a DMC read, and those only happen while the CPU is halted on
	; an opcode fetch (NESdev forum "PAL DMA behavior", RP2A07 traces), so it can never be asserted inside an
	; instruction. The frame counter IRQ can: its flag is set a fixed number of cycles after the $4017 write.
	; How: each pass syncs to the DMC (so the APU's cycle phase at the $4017 write, which decides the write's 3- or
	; 4-cycle delay, is the same every pass), writes $4017 = $00, waits N + 64 - A cycles, then runs
	;     CLI / <3-cycle instruction> / INX / INX / INX
	; and the IRQ handler stores X. Raising A by 1 starts the instruction 1 cycle earlier against the IRQ. X = 0 means
	; the IRQ was taken right after the instruction, X >= 1 after the next one.
	; Two sweeps, identical except for the instruction: a taken BNE to the next instruction, and LDA zp (3 cycles,
	; polls at the end of its 2nd cycle). The branch must switch from X = 0 to X >= 1 exactly one step of A earlier than
	; LDA zp. Only this difference is checked, so the exact frame IRQ cycle and the DMC phase do not matter; N = 33198
	; only centres the sweep: the 4-step flag is set about 33254 cycles after the write (NESdev "APU Frame Counter";
	; blargg's pal_apu_tests), and the instruction starts N + 74 - A cycles after it, i.e. near A = 18.
TEST_IFL_PollSweep_IRQ:
	STX <$58
	LDA $4015                        ; acknowledge the frame IRQ
	RTI                              ; the pushed I flag is clear: carries on with the INX chain
;;;;;;;

TEST_IFlagLatency_TestA:           ; runs both sweeps; returns Z set if test A passes
	LDA #$4C
	STA $600
	LDA #LOW(TEST_IFL_PollSweep_IRQ)
	STA $601
	LDA #HIGH(TEST_IFL_PollSweep_IRQ)
	STA $602
	JSR TEST_IFL_PollSweepBNE
	JSR TEST_IFL_PollSweepLDA
	LDA #$40
	STA $4017
	LDA $4015
	LDY #$00
	JSR TEST_IFL_PollSweep_First
	STX <$54                         ; first A where the BNE sweep is not 0
	LDY #$30
	JSR TEST_IFL_PollSweep_First
	STX <$55                         ; same for LDA zp
	CPX #$FF
	BEQ TEST_IFlagLatency_TestA_Fail ; no transition inside the sweep
	LDA <$54
	BEQ TEST_IFlagLatency_TestA_Fail ; a transition at A = 0: the sweep did not start before it
	CMP #$FF
	BEQ TEST_IFlagLatency_TestA_Fail
	CLC
	ADC #1
	CMP <$55                         ; the branch must switch one step earlier than LDA zp: Z set = pass
	RTS
TEST_IFlagLatency_TestA_Fail:
	LDA #1                           ; Z clear
	RTS
;;;;;;;

TEST_IFL_PollSweepBNE:                         ; one sweep of 36 passes; results (X when the IRQ was taken) at $500-$523
	LDA #0
	STA <$56                         ; A = 0..35: the variable part of the delay (Clockslide64_Minus_A only slides up to A = 38)
TEST_IFL_PollSweepBNE_Pass:
	SEI
	LDA #$40
	STA $4017                        ; frame IRQ off while syncing
	LDA $4015                        ; and acknowledged
	LDA #$FF
	STA <$58                         ; "no IRQ seen"
	JSR DMASync                      ; returns at a fixed point of the DMC's (and so the APU's) cycle
	LDA #$00
	STA $4017                        ; 4-step mode, frame IRQ on. Write cycle = W.
	JSR ClockslideFromWord           ; N = 33198 (see the notes above TEST_IFL_PollSweep_IRQ)
	.word 33198
	LDA <$56                         ; 3
	JSR Clockslide64_Minus_A         ; 64 - A
	LDX #0                           ; 2
	LDA #1                           ; 2   (Z clear, for the BNE)
	CLI                              ; 2   the instruction after this one is the first that can be interrupted
	BNE TEST_IFL_PollSweepBNE_T ; 3 cycles: taken, same page
TEST_IFL_PollSweepBNE_T:
	INX                              ; X = 1
	INX                              ; X = 2
	INX                              ; X = 3
	INX
	NOP
	NOP
	SEI
	LDX <$56
	LDA <$58
	STA $500,X
	INC <$56
	LDA <$56
	CMP #36
	BNE TEST_IFL_PollSweepBNE_Pass
	RTS
;;;;;;;

TEST_IFL_PollSweepLDA:                         ; one sweep of 36 passes; results (X when the IRQ was taken) at $530-$553
	LDA #0
	STA <$56                         ; A = 0..35: the variable part of the delay (Clockslide64_Minus_A only slides up to A = 38)
TEST_IFL_PollSweepLDA_Pass:
	SEI
	LDA #$40
	STA $4017                        ; frame IRQ off while syncing
	LDA $4015                        ; and acknowledged
	LDA #$FF
	STA <$58                         ; "no IRQ seen"
	JSR DMASync                      ; returns at a fixed point of the DMC's (and so the APU's) cycle
	LDA #$00
	STA $4017                        ; 4-step mode, frame IRQ on. Write cycle = W.
	JSR ClockslideFromWord           ; N = 33198 (see the notes above TEST_IFL_PollSweep_IRQ)
	.word 33198
	LDA <$56                         ; 3
	JSR Clockslide64_Minus_A         ; 64 - A
	LDX #0                           ; 2
	LDA #1                           ; 2   (Z clear, for the BNE)
	CLI                              ; 2   the instruction after this one is the first that can be interrupted
	LDA <$00                         ; 3 cycles
	INX                              ; X = 1
	INX                              ; X = 2
	INX                              ; X = 3
	INX
	NOP
	NOP
	SEI
	LDX <$56
	LDA <$58
	STA $530,X
	INC <$56
	LDA <$56
	CMP #36
	BNE TEST_IFL_PollSweepLDA_Pass
	RTS
;;;;;;;

TEST_IFL_PollSweep_First: ; in: Y = base offset ($00 or $30). Out: X = first A with a result other than 0, or $FF
	LDX #0
TEST_IFL_PollSweep_FirstLoop:
	LDA $500,Y
	BNE TEST_IFL_PollSweep_FirstDone
	INY
	INX
	CPX #36
	BNE TEST_IFL_PollSweep_FirstLoop
	LDX #$FF
TEST_IFL_PollSweep_FirstDone:
	RTS
;;;;;;;


	; TEST B OF THE I-FLAG LATENCY TEST, REBUILT FOR THE 2A07 (same method as test A, see above).
	; Question: does a taken branch that crosses a page poll for interrupts before its 4th (last) cycle? It should: it
	; polls where a normal 4-cycle instruction does (NESdev "CPU interrupts", branch instructions). So a taken BNE that
	; crosses a page and LDA abs (4 cycles, polls at the end of its 3rd cycle) must switch from X = 0 to X >= 1 at the
	; same step of A. The BNE sits at $9DFC with its target at $9E00 (a page crossing).
TEST_IFlagLatency_TestB:           ; returns Z set if test B passes
	LDA #$4C
	STA $600
	LDA #LOW(TEST_IFL_PollSweep_IRQ)
	STA $601
	LDA #HIGH(TEST_IFL_PollSweep_IRQ)
	STA $602
	JSR TEST_IFL_PollSweepBNEPage
	JSR TEST_IFL_PollSweepLDAabs
	LDA #$40
	STA $4017
	LDA $4015
	LDY #$00
	JSR TEST_IFL_PollSweep_First
	STX <$54
	LDY #$30
	JSR TEST_IFL_PollSweep_First
	STX <$55
	CPX #$FF
	BEQ TEST_IFlagLatency_TestB_Fail
	LDA <$54
	BEQ TEST_IFlagLatency_TestB_Fail
	CMP #$FF
	BEQ TEST_IFlagLatency_TestB_Fail
	CMP <$55                         ; same step: Z set = pass
	RTS
TEST_IFlagLatency_TestB_Fail:
	LDA #1
	RTS
;;;;;;;
TEST_IFL_PollSweepBNEPage:                         ; 36 passes; results (X when the IRQ was taken) at $500-$523
	LDA #0
	STA <$56
TEST_IFL_PollSweepBNEPage_Pass:
	SEI
	LDA #$40
	STA $4017
	LDA $4015
	LDA #$FF
	STA <$58
	JSR DMASync
	LDA #$00
	STA $4017                        ; write cycle = W
	JSR ClockslideFromWord
	.word 33195                      ; 3 less than in test A: the JMP below adds 3 before the instruction
	LDA <$56                         ; 3
	JSR Clockslide64_Minus_A         ; 64 - A
	LDX #0                           ; 2
	LDA #1                           ; 2
	CLI                              ; 2
	JMP TEST_IFlagLatency_StubBNEPage                ; 3   (both sweeps: the instruction under test sits in a stub)
TEST_IFL_PollSweepBNEPage_Back:
	SEI
	LDX <$56
	LDA <$58
	STA $500,X
	INC <$56
	LDA <$56
	CMP #36
	BNE TEST_IFL_PollSweepBNEPage_Pass
	RTS
;;;;;;;

TEST_IFL_PollSweepLDAabs:                         ; 36 passes; results (X when the IRQ was taken) at $530-$553
	LDA #0
	STA <$56
TEST_IFL_PollSweepLDAabs_Pass:
	SEI
	LDA #$40
	STA $4017
	LDA $4015
	LDA #$FF
	STA <$58
	JSR DMASync
	LDA #$00
	STA $4017                        ; write cycle = W
	JSR ClockslideFromWord
	.word 33195                      ; 3 less than in test A: the JMP below adds 3 before the instruction
	LDA <$56                         ; 3
	JSR Clockslide64_Minus_A         ; 64 - A
	LDX #0                           ; 2
	LDA #1                           ; 2
	CLI                              ; 2
	JMP TEST_IFlagLatency_StubLDAabs                ; 3   (both sweeps: the instruction under test sits in a stub)
TEST_IFL_PollSweepLDAabs_Back:
	SEI
	LDX <$56
	LDA <$58
	STA $530,X
	INC <$56
	LDA <$56
	CMP #36
	BNE TEST_IFL_PollSweepLDAabs_Pass
	RTS
;;;;;;;

TEST_IFlagLatency_StubLDAabs:
	LDA $0000                        ; 4 cycles
	INX
	INX
	INX
	INX
	NOP
	NOP
	JMP TEST_IFL_PollSweepLDAabs_Back
;;;;;;;

	; OPEN-BUS OPCODE PROBE, the 2A07 replacement for "LDA $4000 reads the DMA's byte".
	; A 2A07's DMA only halts the CPU on an opcode fetch (NESdev forum "PAL DMA behavior", RP2A07 traces), so a DMA
	; never shows up in an open-bus data read. It does show up in an opcode fetched from open bus: JMP $4000 fetches
	; its next opcode from open bus, which is the $40 of the JMP's operand (RTI), unless the DMA halts the CPU on that
	; very fetch; then the repeated fetch reads the DMA's sample byte. With a $00 sample byte that is BRK, which goes to
	; $0600 -> TEST_OBProbe_Hit.
	; Use: JSR TEST_OBProbe_Install with the return label in A (low) / X (high); before the timed part. Then, timed:
	;     LDA #HIGH(ret) / PHA / LDA #LOW(ret) / PHA / PHP / JMP $4000      (13 cycles to the JMP's opcode fetch,
	; whose $4000 fetch is 3 cycles later). ret: <$50> = 1 if the DMA landed on the $4000 fetch, 0 if not.
	; The DMA lands there if it is requested in the 3 cycles up to that fetch (the first opcode fetch at or after the
	; request, rules R2/R3 of the 2A07 DMA rules).
TEST_OBProbe_Install:
	STA <$5E
	STX <$5F
	LDA #0
	STA <$50
	LDA #$4C
	STA $600
	LDA #LOW(TEST_OBProbe_Hit)
	STA $601
	LDA #HIGH(TEST_OBProbe_Hit)
	STA $602
	RTS
TEST_OBProbe_Hit:                  ; BRK from the probe: drop the BRK's 3 bytes and the probe's 3, report, go on
	PLA                                ; (PLA, not TSX/TXS: X must survive, the callers keep loop counters in it)
	PLA
	PLA
	PLA
	PLA
	PLA
	LDA #1
	STA <$50
	JMP [$005E]
;;;;;;;


	; THE CYCLE CLOCK ON A 2A07, measured against the frame counter IRQ.
	; Why not the DMC: every DMC read on a 2A07 falls on a fixed parity and its DMA only halts on opcode fetches, so
	; each DMA re-aligns the CPU to the APU's 2-cycle grid and erases the odd/even part of any earlier timing difference
	; (traced: a run started one cycle later gave the identical DMA sequence). The frame counter IRQ is not a DMA: its
	; flag is set a fixed number of cycles after the $4017 write (NESdev "APU Frame Counter"; blargg's pal_apu_tests).
	; Measures, as before, the CPU cycles from the end of CycleClockBegin's RTS to the start of the JSR to
	; CycleClockEnd. Each pass: DMASync (so the APU's cycle phase at the $4017 write, which decides its 3- or 4-cycle
	; delay, is the same every pass; the sync's last DMA falls in the fixed wait right after it), $4017 = $00, a fixed
	; wait, a variable wait of 255 - d cycles, then the measured code (re-entered by RTS with S, X and Y as at
	; CycleClockBegin), then CLI and a chain of INX. The IRQ handler records X. Raising d by one starts everything one
	; cycle earlier against the IRQ, so X can only grow with d; a binary search finds the smallest d with X >= 2 (8
	; passes). The same search on an empty interval (CheckDMATiming) gives the reference, and N = d - reference.
	; Only differences are used, so the exact IRQ cycle does not matter; the 256-cycle window leaves room for console
	; differences of the absolute offset. Measured code: up to about 200 cycles; it runs once per pass (about 8 times),
	; must not depend on A, and must not use the IRQ, the frame counter or the DMC.
	; RAM: $07E1 saved S, $07E2/$07E3 return address, $07E4/$07E5 X/Y, $07E6 lo, $07E7 hi, $07E8 reference,
	; $07E9 last result, $07EB X at the IRQ, $07EC d, $07D0-$07D6 the variable-wait stub (JSR ClockslideFromWord /
	; .word / RTS).
CycleClock2_Begin:
	LDA <$00                         ; ClockslideFromWord uses $00/$01; the measured code may too (JMP ($0000) test)
	STA $07DC
	LDA <$01
	STA $07DD
	LDA $600                         ; keep the measured code's own IRQ/BRK target (the BRK timing test puts RTI there)
	STA $07D8
	LDA $601
	STA $07D9
	LDA $602
	STA $07DA
	STX $07E4
	STY $07E5
	TSX
	STX $07E1
	LDA $0101,X
	STA $07E2
	LDA $0102,X
	STA $07E3
	LDY #0                           ; keep the 8 stack bytes above the return address: the measured code may read
CycleClock3_SaveStack:               ; them (RTI pulls bytes the test pushed) and its JSR to CycleClockEnd may write
	LDA $0103,X                      ; over them, so every pass puts them back
	STA $07C0,Y
	INX
	INY
	CPY #8
	BNE CycleClock3_SaveStack
	LDY $07E5
	LDA #0
	STA $4015                        ; DMC off for the whole measurement
	LDA #$20                         ; the stub: JSR ClockslideFromWord / .word (filled per pass) / RTS
	STA $07D0
	LDA #LOW(ClockslideFromWord)
	STA $07D1
	LDA #HIGH(ClockslideFromWord)
	STA $07D2
	LDA #$60
	STA $07D5
	LDA #0
	STA $07E6                        ; lo = 0
	LDA #255
	STA $07E7                        ; hi = 255
	STA $07EC                        ; First pass at d = 255 (the latest start): the INX chain is long enough that
	LDA #1                           ; the IRQ lands inside it, and X tells where in 2-cycle steps (CycleClock3_Result)
	STA $07EF
	JMP CycleClock3_Pass
CycleClock3_Search:
	LDA $07E6
	CMP $07E7
	BEQ CycleClock3_Found
	CLC
	ADC $07E7
	ROR A                            ; mid = (lo + hi) / 2 (9-bit sum through the carry)
	STA $07EC
	JMP CycleClock3_Pass
CycleClock3_Result:                  ; X at the IRQ in $07EB
	LDA $07EF
	BEQ CycleClock3_Result2
	LDA #0                           ; The first (coarse) pass. X grows by one every 2 cycles of d past the step
	STA $07EF                        ; d* where it reaches 2, so d* = 255 - 2(X - 2) - 1 or 255 - 2(X - 2): one more
	LDA $07EB                        ; pass at the lower one decides. Outside 3..63 (IRQ too early, or no IRQ in the
	CMP #3                           ; chain) the full binary search over 0..255 runs instead.
	BCC CycleClock3_Search
	CMP #64
	BCS CycleClock3_Search
	SEC
	SBC #2
	ASL A                            ; 2(X - 2)
	STA $07E9
	LDA #255
	SEC
	SBC $07E9                        ; c = 255 - 2(X - 2)
	STA $07E7                        ; hi = c
	SEC
	SBC #1
	STA $07E6                        ; lo = c - 1
	JMP CycleClock3_Search
CycleClock3_Result2:
	LDA $07EB
	CMP #2
	BCS CycleClock3_Late
	LDA $07EC                        ; X < 2: too early, d must be larger
	CLC
	ADC #1
	STA $07E6
	JMP CycleClock3_Search
CycleClock3_Late:
	LDA $07EC                        ; X >= 2: d is large enough
	STA $07E7
	JMP CycleClock3_Search
CycleClock3_Found:
	STA $07E9
	SEC
	SBC $07E8                        ; N = d - reference
	TAY
	LDA #$40
	STA $4017                        ; frame IRQ off
	LDA $4015
	LDA #0
	STA $4015                        ; DMC off
	LDA $07D8                        ; give the measured code its IRQ/BRK target back (otherwise the next measurement
	STA $600                         ; would copy the clock's own JMP as "the measured code's handler" and a BRK
	LDA $07D9                        ; would loop through it forever)
	STA $601
	LDA $07DA
	STA $602
	LDX $07EE                        ; return to CycleClockEnd's caller with the stack as the last pass's JSR to
	TXS                              ; CycleClockEnd left it
	LDX $07E4
	JMP CycleClock3_Exit
CycleClock3_Pass:
	SEI
	LDA #0
	STA $07ED                        ; an IRQ before CycleClockEnd does not count
	LDA #$4C                         ; IRQ/BRK target
	STA $600
	LDA #LOW(CycleClock3_IRQ)
	STA $601
	LDA #HIGH(CycleClock3_IRQ)
	STA $602
	LDA #$40
	STA $4017
	LDA $4015
	LDA #255                         ; the variable wait: 255 - d (+ a base inside the stub's word)
	SEC
	SBC $07EC
	CLC
	ADC #LOW(300)
	STA $07D3
	LDA #HIGH(300)
	ADC #0
	STA $07D4
	LDX $07E1                        ; the stack as at CycleClockBegin, with its return address put back on top
	TXS
	LDA $07E2
	STA $0101,X
	LDA $07E3
	STA $0102,X
	LDY #0
CycleClock3_RestoreStack:
	LDA $07C0,Y
	STA $0103,X
	INX
	INY
	CPY #8
	BNE CycleClock3_RestoreStack
	LDA #$07                         ; OAM DMA instead of DMASync for a fixed point of the APU cycle: the CPU
	STA $4014                        ; resumes on the same get/put phase after every OAM DMA (NESdev "DMA"; the 2A07
	                                 ; traces show OAM DMA works as on the 2A03, NESdev forum t=25939), and it takes
	                                 ; 513-514 cycles instead of the many passes of the DMC sync. The DMC is off
	                                 ; (CycleClockBegin), so no DMA falls anywhere in the pass. Copies page 7 into OAM.
	LDA #$00
	STA $4017                        ; 4-step mode, frame IRQ on: the flag comes about 33253 cycles later
	JSR ClockslideFromWord           ; fixed part of the wait: centres the window. From the $4017 write to the CLI is
	.word 32790                      ; about 32790 + (300 + 255 - d + 12) + 25, i.e. 33253 (the flag) near d = 128
	JSR $07D0                        ; variable part: 300 + 255 - d
	LDA $07DC                        ; 4  give the measured code its $00/$01 back (ClockslideFromWord overwrote them)
	STA <$00                         ; 3
	LDA $07DD                        ; 4
	STA <$01                         ; 3
	LDX $07E4                        ; 4
	LDY $07E5                        ; 4
	RTS                              ; 6  into the measured code
CycleClock2_End:                     ; reached by JMP from CycleClockEnd
	TSX                              ; 2  the stack pointer CycleClockEnd's caller left (the measured code may push or
	STX $07EE                        ; 4  pull, e.g. PHP / PLP): the final return uses it
	LDX #0                           ; 2  X first: if the measured code left I clear (CLI), an IRQ can be taken from
	LDA #$80                         ; 2  here on, and must then read as "too early" (X = 0), as it does inside the
	STA $07ED                        ; 4  measured code (flag still 0, see CycleClock3_IRQ). The X >= 2 step that the
	                                 ;    search looks for lies after the CLI below, where I is clear either way.
	CLI                              ; 2  the first instruction that can be interrupted is the INX after this one
	INX                              ; X = 1
	INX                              ; X = 2 (64 INX: a 128-cycle window for the first pass)
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	SEI
	LDX #$FF                         ; no IRQ inside the chain: as late as it gets
	STX $07EB
	JMP CycleClock3_Next
CycleClock3_IRQ:                     ; the frame IRQ, or a BRK executed by the measured code
	BIT $07ED                        ; 4  $80 once CycleClockEnd's chain has begun
	BMI CycleClock3_IRQ_Chain        ; 2
	PHA                              ; 3  before the chain: a BRK of the measured code, or an IRQ let in by its CLI
	TXA                              ; 2
	PHA                              ; 3
	TSX                              ; 2
	LDA $0103,X                      ; 4  the flags pushed by the BRK / IRQ
	AND #$10                         ; 2  B: a BRK
	BEQ CycleClock3_IRQ_Early        ; 2
	PLA                              ; 4
	TAX                              ; 2
	PLA                              ; 4
	JMP $07D8                        ; 3  the measured code's own handler (40 cycles from the vector fetch to here,
	                                 ;    counting the JMP at $0600; the BRK timing test adds them to its key)
CycleClock3_IRQ_Early:
	LDX #0                           ; taken inside the measured code (it cleared I): too early
CycleClock3_IRQ_Chain:
	STX $07EB
	LDA $4015                        ; acknowledge the frame IRQ
CycleClock3_Next:
	LDA #$40
	STA $4017
	LDX $07E1                        ; drop whatever the measured code and the IRQ left on the stack
	TXS
	JMP CycleClock3_Result
;;;;;;;

	; JSR $4000 PROBE for the 2A07 form of [DMA Landing on Write] tests 3-5.
	; JSR takes 6 cycles: opcode fetch (c0), operand low (c1), dummy stack read (c2), push PCH (c3, write), push PCL
	; (c4, write), operand high (c5), and the next opcode fetch is at $4000 (c6), from open bus: the $40 of the
	; operand, RTI. A 2A07 DMA only halts the CPU on an opcode fetch (NESdev forum "PAL DMA behavior", t=25939; on PAL
	; "all cycles that are not the initial opcode fetch" delay the halt, t=26827), so a DMA requested on c1-c6 lands on
	; the $4000 fetch and its byte ($00) turns the opcode into BRK -> TEST_OBProbe_Hit. On a 2A03 a request on c2 or
	; c5 halts there (a read), and one on c3/c4 (writes) halts on c5, so it never reaches the $4000 fetch.
	; Stack: the caller pushes $9D, the JSR pushes $9D04; an RTI there (no DMA) pulls P = $04 (I set), PC = $9D9D.
	; A BRK (DMA) leaves 3 more bytes; TEST_OBProbe_Hit drops 6 either way... (3 + 2 + 1) and reports <$50> = 1.
	; [Sprite 0 Hit behavior] is placed here, in bank 0's free space before $9D02 (bank 1 is full).
TEST_Sprite0Hit_Behavior:
	; Some prep.
	JSR PREP_SpriteZeroHit
	
	;;; Test 1 [Sprite Zero Hit Behavior]: Does a sprite zero hit occur in a situation in which it should? ;;;
	; What is a sprite zero hit?
	; Every slot in Object Attribute Memory (OAM) can be numbered from 0 to 63.
	; The object in slot zero will be referred to as "Sprite Zero".
	; The "CHR" byte in OAM determines which index from the pattern table to use for the graphics.
	; Each pixel drawn will take 2 bits from the pattern data, and if the value is 00, it will be rendered with "the background color".
	; If the 2 bits are 01, 10, or 11, then this pixel will be drawn with color 1, 2, and 3 of the specified color palette respectively. (with color 0 being the background color)
	; Let's refer to any pixel that is using a non-background-color as a "solid pixel".
	; Keep in mind, this "solid pixel" terminology is only referring to the 2 bits from the pattern data, and has nothing to do with the actual colors drawn.
	; A "sprite zero hit" occurs when the following happens:
	; A solid pixel of sprite zero is drawn on the same pixel as a solid pixel of the background.
	; And if a sprite zero hit was detected, bit 6 of address $2002 is set, similar to how the VBlank flag is using bit 7 of the same address.
	
	; So let's work this one out.
	; A solid white square has been placed at VRAM address $2001. (We reset the scroll with the value $2000, so this square is 8 pixels to the right of the upper left of the screen)
	; We have initialized Sprite Zero as a white square, and set it's screen coordinates to ($08, $00) which should overlap the box. (But it will be 1 pixel lower)
	; Therefore, a solid pixel of Sprite Zero is guaranteed to overlap a solid pixel of this white square in the background.
	
	JSR EnableRendering_S ; start rendering sprites!
	LDX #02
	STX $4014 ; OAM DMA
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and the sprite zero hit to occur. (we're not going for precise timing on this test. Just to see if it happens.)
	LDA $2002	; Bit 6 should be set, since the sprite zero hit should have occurred.
	AND #$40
	BNE TEST_S0H_Skip1
FAIL_Sprite0Hit_Behavior_N0:
	JMP FAIL_Sprite0Hit_Behavior
TEST_S0H_Skip1:
	INC <ErrorCode

	;;; Test 2 [Sprite Zero Hit Behavior]: Sprite zero hits should not happen if Background Rendering is disabled. ;;;
	JSR DisableRendering_BG ; only disable rendering the background.
	JSR WaitForVBlank
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should not occur, for the background is not rendering.)
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior_N0
	INC <ErrorCode

	;;; Test 3 [Sprite Zero Hit Behavior]: Sprite zero hits should not happen if Sprite Rendering is disabled. ;;;
	JSR WaitForVBlank
	JSR EnableRendering_BG ; enable the background
	JSR DisableRendering_S ; and disable sprites
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should not occur, for sprites are not rendering.)
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior_N0
	INC <ErrorCode

	;;; Test 4 [Sprite Zero Hit Behavior]: Sprite zero hits should not happen if both sprites and background Rendering are disabled. ;;;
	JSR WaitForVBlank
	JSR DisableRendering_BG ; enable the background
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should not occur, for rendering is disabled.)
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior_N0
	INC <ErrorCode
	
	;;; Test 5 [Sprite Zero Hit Behavior]: Sprite zero hits should not happen if sprite zero is completely transparent. ;;;
	JSR WaitForVBlank
	JSR EnableRendering  ; enable the background and sprites.
	JSR InitializeSpriteZero ; Init sprite zero with a completely transparent sprite. (All pixels are background-color)
	;    YPos, CHR, Att, XPos
	.byte $00, $24, $00, $08
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should not occur, for sprite zero as no solid pixels.)
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior
	INC <ErrorCode	
	
	;;; Test 6 [Sprite Zero Hit Behavior]: Sprite zero hits can happen at X=254. (verify for the next test) ;;;
	JSR WaitForVBlank	
	JSR PrintCHR
	.word $201F ; At address $201F
	.byte $FC, $FF
	JSR ResetScroll
	JSR InitializeSpriteZero
	;    YPos, CHR, Att, XPos
	.byte $00, $FC, $00, $FE
	JSR WaitForVBlank
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should occur.)
	LDA $2002	; Bit 6 should be set, since the sprite zero hit should have occurred.
	AND #$40
	BEQ FAIL_Sprite0Hit_Behavior
	INC <ErrorCode
	
	;;; Test 7 [Sprite Zero Hit Behavior]: Sprite zero hits cannot happen at X=255. ;;;
	JSR WaitForVBlank	
	JSR InitializeSpriteZero
	;    YPos, CHR, Att, XPos
	.byte $00, $FC, $00, $FF
	JSR WaitForVBlank
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should not occur, for sprite zero is at X=255.)
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior
	INC <ErrorCode

	;;; Test 8 [Sprite Zero Hit Behavior]: Sprite zero hits should not happen if sprite zero is at X=0, and the PPU's 8 pixel mask is enabled (show BG, no sprite). ;;;
	JSR WaitForVBlank
	JSR PrintCHR
	.word $2000 ; At address $2000
	.byte $FC, $FF
	JSR ResetScroll
	JSR EnableRendering  ; enable the background and sprites.
	LDA #$1A
	STA $2001 ; enable the background in the left 8 pixels, but not sprites
	JSR InitializeSpriteZero
	;    YPos, CHR, Att, XPos
	.byte $00, $FC, $00, $00
	JSR WaitForVBlank
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should not occur, for sprite zero is masked away.)
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior
	INC <ErrorCode	
	BNE TEST_Sprite0Hit_Behavior_Continued ; branch always around this fail condition.
	
FAIL_Sprite0Hit_Behavior:
	JSR ClearOverscanNametable
	JSR WaitForVBlank
	JSR DisableRendering_S
	JSR EnableRendering_BG
	JMP TEST_Fail
	
TEST_Sprite0Hit_Behavior_Continued:
	;;; Test 9 [Sprite Zero Hit Behavior]: Sprite zero hits should not happen if sprite zero is at X=0, and the PPU's 8 pixel mask is enabled (show sprite, no BG). ;;;
	JSR WaitForVBlank
	LDA #$1C
	STA $2001 ; enable the sprites in the left 8 pixels, but not BG
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should not occur, for sprite zero is masked away.)
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior
	INC <ErrorCode	

	;;; Test A [Sprite Zero Hit Behavior]: Despite the 8 pixel mask, if the sprite has visible pixels beyond the mask (X>0, X<8) the Sprite Zero Hit occurs. ;;;
	JSR WaitForVBlank
	JSR InitializeSpriteZero
	;    YPos, CHR, Att, XPos
	.byte $00, $FC, $00, $01	; Xpos = 1
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should occur, for some sprite zero is visible.)
	LDA $2002	; Bit 6 should be set, since the sprite zero hit should have occurred.
	AND #$40
	BEQ FAIL_Sprite0Hit_Behavior
	INC <ErrorCode	

	;;; Test B [Sprite Zero Hit Behavior]: Sprite zero hits can happen at Y=238. (verify for the next test) ;;;
	JSR WaitForVBlank	
	JSR PrintCHR
	.word $23A1 ; At address $23A1
	.byte $FC, $FF	; solid white square.
	JSR ResetScroll
	JSR InitializeSpriteZero
	;    YPos, CHR, Att, XPos
	.byte 238, $FC, $00, $08
	JSR WaitForVBlank
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR Clockslide_PALFrame ; Wait an entire PAL frame, since this sprite is at the bottom of the screen. (Sprite Zero hit should occur.)
	LDA $2002	; Bit 6 should be set, since the sprite zero hit should have occurred.
	AND #$40
	BEQ FAIL_Sprite0Hit_Behavior
	INC <ErrorCode
	
	;;; Test C [Sprite Zero Hit Behavior]: Sprite zero hits cannot happen at Y>=239. ;;;
	JSR WaitForVBlank	
	JSR InitializeSpriteZero
	;    YPos, CHR, Att, XPos
	.byte 239, $FC, $00, $08
	JSR WaitForVBlank
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR Clockslide_PALFrame ; Wait an entire PAL frame, since this sprite is at the bottom of the screen. (Sprite Zero hit should NOT occur.)
	JSR Clockslide_500 ; wait a few more scanlines just to be sure.
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BEQ TEST_S0H_Skip5
FAIL_Sprite0Hit_Behavior2_N4:
	JMP FAIL_Sprite0Hit_Behavior2
TEST_S0H_Skip5:
	INC <ErrorCode

	;;; Test D [Sprite Zero Hit Behavior]: Sprite Zero Hit test with a sprite that isn't a solid 8x8 square. ;;;
	; If this test fails, it could be for one of two reasons.
	; Either, A: Your sprites are being rendered one scanline higher than they should be. (Though I assume if it passes test C that's not the case)
	; Or B: Your sprite zero hit detection isn't actually checking for "solid pixels" overlapping.
	JSR WaitForVBlank
	JSR PrintCHR
	.word $2002 ; At address $2001
	.byte $E1, $FF ; $E1 is a full 8x8 square with a single pixel missing around the middle of it.
	JSR ResetScroll
	JSR InitializeSpriteZero
	;    YPos, CHR, Att, XPos
	.byte $02, $C0, $00, $13	; CHR $C0 is a 1x1 pixel dot. Position ($13, $02) should be lined up perfectly so this one dot sprite falls in the 1x1 hole of the tile.
	STX $4014 ; OAM DMA (we want to keep OAM refreshed for these tests)
	JSR ClockslideFromWord ; PAL VBlank is 7459 CPU cycles (2C02 version: 3000 of a 2273-cycle VBlank)
	.word 7646 ; Wait long enough for VBlank to be over, and a few scanlines to render. (Sprite Zero hit should miss, since the visible pixel of the sprite isn't overlapping the tile's visible pixels)
	LDA $2002	; Bit 6 should NOT be set, since the sprite zero hit should not have occurred.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior2_N4
	INC <ErrorCode	
	
	;;; Test E [Sprite Zero Hit Behavior]: The sprite zero hit flag is not set until the PPU cycle in which the dot is drawn. ;;;
	JSR WaitForVBlank
	JSR InitializeSpriteZero
	;    YPos, CHR, Att, XPos
	.byte $00, $FC, $00, $FE
	JSR DisableRendering
	LDA #0
	JSR VblSync_Plus_A
	; The sprite zero hit will occur at X=254 of scanline 1 (dot 255 of scanline 1).
	; PAL: from dot 1 of scanline 241, that is 71 scanlines of VBlank (241-311), scanline 0, and 253 dots into
	; scanline 1: (71+1)*341 + 253 = 24805 PPU dots, 7751.6 CPU cycles at 3.2 dots per cycle. The waits below are
	; set by measurement (see the .word comment), because VblSync_Plus_A's exact return point is not dot 1.
	LDA #0
	STA $2003 ; OAMADDR = 0: the 2C07's forced refresh moved it while rendering was off (+6 CPU cycles)
	STX $4014 ; OAM DMA
	JSR EnableRendering
	JSR ClockslideFromWord
	.word 7167 ; PAL: the read below first sees the hit with a wait of 7169, so this read is 2 CPU cycles
	            ; early (6.4 dots), and the second one (2 NOPs later) 2 cycles late. The 2C02 version: 1.33 early, 2.67 late.
	LDA $2002	; This should read 1 CPU cycles *BEFORE* the sprite zero hit flag is set.
	AND #$40
	BNE FAIL_Sprite0Hit_Behavior2_N4
	LDA #0
	JSR VblSync_Plus_A
	LDA #0
	STA $2003 ; OAMADDR = 0: the 2C07's forced refresh moved it while rendering was off (+6 CPU cycles)
	STX $4014 ; OAM DMA
	JSR EnableRendering
	JSR ClockslideFromWord
	.word 7167 ; (see above)
	NOP
	NOP ; the read below is 4 CPU cycles later than the first: 2 cycles after the hit.
	LDA $2002	; This should read 2 CPU cycles *AFTER* the sprite zero hit flag is set.
	AND #$40
	BNE TEST_S0H_Skip8
	JMP FAIL_Sprite0Hit_Behavior2	
TEST_S0H_Skip8:
	;; END OF TEST ;;
	JSR ClearOverscanNametable
	LDA #1
	RTS
;;;;;;;

	.org $9D02
TEST_DLW_JSRProbe:
	JSR $4000
Test_2004_Stress_OAM:
	.byte $80, $00, $00, $FF
	.byte $7F, $01, $20, $EE
	.byte $7E, $02, $40, $DD
	.byte $7D, $03, $60, $CC
	.byte $7C, $04, $80, $BB
	.byte $7B, $05, $A0, $AA
	.byte $7A, $06, $C0, $99
	.byte $79, $07, $E0, $88

KeyNext:
	; The next byte of an LZ-compressed key, decoded through a 256-byte window in page 6 (page 6 only holds handlers
	; that each test writes before it uses them). Tokens: 0LLLLLLL = L literal bytes; 1LLLLLLL, d = copy L bytes from
	; d bytes back; $80, address = the data continues at that address (the keys are split across free ROM space).
	; State: $40/$41 source, $42 bytes left in the token, $43 token, $44 copy distance, $45 window position.
	LDY #0
	LDA <$42
	BNE KN_Have
KN_Token:
	LDA [$40],Y
	JSR KN_Inc
	CMP #$80
	BNE KN_NotJump
	LDA [$40],Y
	TAX
	INY
	LDA [$40],Y
	STA <$41
	STX <$40
	DEY
	BEQ KN_Token
KN_NotJump:
	STA <$43
	AND #$7F
	STA <$42
	BIT <$43
	BPL KN_Have
	LDA [$40],Y
	STA <$44
	JSR KN_Inc
KN_Have:
	DEC <$42
	BIT <$43
	BMI KN_Copy
	LDA [$40],Y
	JSR KN_Inc
	JMP KN_Out
KN_Copy:
	LDA <$45
	SEC
	SBC <$44
	TAX
	LDA $600,X
KN_Out:
	LDX <$45
	STA $600,X
	INC <$45
	RTS
KN_Inc:
	INC <$40
	BNE KN_IncDone
	INC <$41
KN_IncDone:
	RTS
;;;;;;;
	.org $9D9D
TEST_DLW_JSRProbe_NotYet:            ; RTI from $4000 (no DMA landed on that fetch) arrives here with the stack clean
	JMP [$005E]
TEST_DLW_LoadPrep:                   ; Setup shared by [DMA Landing on Write] tests 6, 7 and 9
	LDA #0
	STA $4015                         ; DMC off
	LDA #$0F
	STA $4010                         ; no loop, no IRQ, rate $F
	LDA #$FF
	STA $4012                         ; sample at $FFC0 (a $00 byte)
	LDA #0
	STA $4013                         ; 1 byte
	JMP Clockslide_1000               ; let the sample buffer empty (a load DMA only happens into an empty buffer)
;;;;;;;

KEYDATA_5:
	.byte $83, $01
	.byte $82, $75
	.byte $94, $01
	.org $9DFC
TEST_IFlagLatency_StubBNEPage:
	BNE TEST_IFlagLatency_StubBNEPage_T ; at $9DFC: taken, crosses to $9E00, 4 cycles
	.byte $EA, $EA
TEST_IFlagLatency_StubBNEPage_T:     ; $9E00
	INX
	INX
	INX
	INX
	NOP
	NOP
	JMP TEST_IFL_PollSweepBNEPage_Back
;;;;;;;

	; (STR_Eval continued)
SE_NextO:
	INC <$5D
	LDA <$5D
	CMP <$4A
	BEQ SE_NextC
	JMP SE_O
SE_NextC:
	INC <$5C
	LDA <$5C
	CMP #5
	BEQ SE_None
	JMP SE_C
SE_None:
	LDA #0
	RTS
SE_Next: ; the next sample: j + 1, and its dot 1.6 further
	INC <$5A
	LDA <$4E
	CLC
	ADC #16
SE_Next1:
	CMP #10
	BCC SE_Next2
	SBC #10
	INC <$56
	BNE SE_Next1
	INC <$57
	JMP SE_Next1
SE_Next2:
	STA <$4E
	RTS
;;;;;;;
	.org $9E61
STR_SKIP = $21 ; a value no stress-test key contains
STR_Eval:
	; Shared evaluation of [$2004 Stress Test] and [$2007 Stress Test] (PAL). The samples at $500+j landed on dot
	; d = o + floor((1 + 2c + 16j) / 10): the reads move 1.6 dots per sample (per pass), and with the CPU/PPU phase
	; unknown the landing dots follow one of 5 patterns c. The key is the 2C02 version's value for each dot 0-340,
	; stored LZ-compressed (KeyNext); a key byte of STR_SKIP means "not checked" (dots the 2C02 version does not check,
	; or that depend on the CPU/PPU alignment). Each pattern c and offset o (o+64 from olo to ohi-1) is tried; the test
	; passes if one matches every checked sample, with at least "min" checks.
	; Inline after the JSR: .word stream, .byte samples, olo, ohi, min, mode. Mode 0: the key has a byte for every dot.
	; Mode 1: the key has bytes only for odd dots 1-339 except dot % 8 = 7, the only dots checked. Out: A = 1 (pass) or 0.
	JSR CopyReturnAddressToByte0
	LDY #0
SE_Params:
	LDA [$0000],Y
	STA $0046,Y ; $46/$47 stream, $48 samples, $49 olo, $4A ohi, $4B min, $4C mode
	INY
	CPY #7
	BNE SE_Params
	JSR FixRTS
	LDA #0
	STA <$5C ; c
SE_C:
	LDA <$49
	STA <$5D ; o + 64
SE_O:
	LDA <$46
	STA <$40
	LDA <$47
	STA <$41
	LDA #0
	STA <$42 ; decoder: nothing pending
	STA <$45 ; decoder: window position
	STA <$57 ; D = d + 64, high byte
	STA <$59 ; dot + 64, high byte
	STA <$4F ; checks
	STA <$5A ; j
	LDA <$5C
	ASL A
	ORA #1
	STA <$4E ; tenths accumulator
	LDA <$5D
	STA <$56
	LDA #64
	STA <$58 ; dot 0
SE_Skip:
	LDA <$57
	BNE SE_Dot
	LDA <$56
	CMP #64
	BCS SE_Dot
	JSR SE_Next ; samples before dot 0
	JMP SE_Skip
SE_Dot:
	LDY #STR_SKIP
	LDA <$4C
	BEQ SE_Fetch ; mode 0: a key byte for every dot
	LDA <$58     ; dot + 64 (64 is even, so parity and dot % 8 are the dot's)
	LSR A
	BCC SE_Fetched ; even dot: not checked, no key byte
	AND #3
	CMP #3
	BEQ SE_Fetched ; dot % 8 = 7: not checked, no key byte
SE_Fetch:
	JSR KeyNext
	TAY
SE_Fetched:
	LDA <$5A
	CMP <$48
	BCS SE_DotDone ; no samples left
	LDA <$56
	CMP <$58
	BNE SE_DotDone
	LDA <$57
	CMP <$59
	BNE SE_DotDone
	CPY #STR_SKIP
	BEQ SE_Unchecked
	TYA
	LDX <$5A
	CMP $500,X
	BEQ SE_Match
	JMP SE_NextO ; mismatch: next offset
SE_Match:
	INC <$4F
SE_Unchecked:
	JSR SE_Next
SE_DotDone:
	INC <$58
	BNE SE_NoCarry
	INC <$59
SE_NoCarry:
	LDA <$59
	BEQ SE_Dot
	LDA <$58
	CMP #$95 ; dot + 64 = $195: all 341 dots done
	BNE SE_Dot
	LDA <$4F
	CMP <$4B
	BCS SE_Passed
	JMP SE_NextO
SE_Passed:
	LDA #1
	RTS
KEYDATA_0:
KEY_2007:
	.byte $64, $02, $C0, $46, $03, $C0, $06, $04, $C1, $6C, $05, $C1, $60, $06, $C1, $60
	.byte $07, $C1, $06, $08, $C2, $66, $09, $C2, $66, $0A, $C2, $24, $0B, $C2, $66, $0C
	.byte $C3, $66, $0D, $C3, $64, $0E, $C3, $60, $0F, $C3, $60, $10, $C4, $66, $11, $C4
	.byte $66, $12, $C4, $18, $13, $C4, $0C, $14, $C5, $6C, $15, $C5, $60, $16, $C5, $76
	.byte $17, $C5, $72, $18, $C6, $66, $19, $C6, $7C, $1A, $C6, $3C, $1B, $C6, $7C, $1C
	.byte $C7, $3C, $1D, $C7, $7E, $1E, $C7, $66, $1F, $C7, $66, $00, $C0, $3C, $01, $C0
	.byte $18, $02, $00, $FF, $00
	.byte $95, $03
	.byte $07, $C0, $66, $01, $C0, $38, $02, $02
KEY_2004_1:
	.byte $02, $7F, $FF
	.byte $C1, $01
	.byte $3F, $FB, $FB, $F7, $F7, $F3, $F3, $EF, $EF, $EB, $EB, $E7, $E7, $E3, $E3, $DF
	.byte $DF, $DB, $DB, $D7, $D7, $D3, $D3, $CF, $CF, $CB, $CB, $C7, $C7, $C3, $C3, $BF
	.byte $BF, $BB, $BB, $B7, $B7, $B3, $B3, $AF, $AF, $AB, $AB, $A7, $A7, $A3, $A3, $9F
	.byte $9F, $9B, $9B, $97, $97, $93, $93, $8F, $8F, $8B, $8B, $87, $87, $83, $83, $7F
	.byte $40, $7F, $7E, $7E, $61, $61, $7C, $7C, $7B, $7B, $7A, $7A, $61, $61, $78, $78
	.byte $77, $77, $73, $73, $6F, $6F, $6B, $6B, $67, $67, $63, $63, $5F, $5F, $5B, $5B
	.byte $57, $57, $53, $53, $4F, $4F, $4B, $4B, $47, $47, $43, $43, $3F, $3F, $3B, $3B
	.byte $37, $37, $33, $33, $2F, $2F, $2B, $2B, $27, $27, $23, $23, $1F, $1F, $1B, $1B
	.byte $17
	.byte $80, LOW(KEYDATA_1), HIGH(KEYDATA_1) ; continued
	.bank 1
	.org $A000	; This next line of code is located at address $A000 in the ROM.
	
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                 TESTS                   ;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	
	
TEST_RamMirroring:
	; The $500 page is cleared to all zeroes before the test.
	
	;;; Test 1 [RAM Mirroring]: Reading from mirrors. ;;;
	; When the address bus is in the range $0000 to $1FFF, the CPU will read from RAM.
	; However, RAM only has $800 bytes of memory.
	; When reading from $800 through $1FFF, the CPU still reads from RAM, but only using the lower eleven bits for the address.
	; Therefore, reading from address $0800 is the same thing as reading from $0000. Likewise, $1000 and $1800 also read address $0000.
	; These are referred to as "mirrors" of address $0000. Likewise, $1FFF is a mirror of $07FF, and so on.
	LDA #1
	STA $501 ; Store 1 at $501
	LDA #2
	STA $580 ; Store 2 at $580
	LDA $D01 ; Read from a mirror of $501
	CMP #1
	BNE TEST_Fail ; if any value other than 1 is read, that's a fail.
	LDA $1D80 ; Read from a mirror of $580
	CMP #2
	BNE TEST_Fail ; if any value other than 2 is read, that's a fail.
	INC <ErrorCode 
	
	;;; Test 2 [RAM Mirroring]: writing to mirrors. ;;;
	; The description of test 1 only mentions reading from mirrors, but writing to them follows the exact same behavior.
	LDA #3
	STA $1D02 ; write to a mirror of $502
	LDA #4
	STA $DDD ; write to a mirror of $5DD
	LDA $502 ; Read $502
	CMP #3
	BNE TEST_Fail ; if any value other than 3 is read, that's a fail.
	LDA $5DD ; Read $5DD 
	CMP #4
	BNE TEST_Fail ; if any value other than 3 is read, that's a fail.
	;; END OF TEST ;;	
	LDA #01 ; PASS!
	RTS
;;;;;;;

TEST_Fail:
	LDA <ErrorCode
	ASL A
	ASL A
	ORA #02 ; Fail
	RTS
;;;;;;;

TEST_OpenBus:
	;;; Test 1 [Open Bus]: Reading from open bus is not all zeroes. ;;;
	; Alright. What is "Open Bus"?
	; When reading from an address that isn't mapped to memory, the data pins are left "floating".
	; Let's learn about the data bus.
	; For instance, imagine LDA <$00. This is a 3 cycle instruction.
	; 1. Fetch the opcode:
	;	- The value of the PC is transferred to the Address Bus, and that address is read. The PC is also incremented.
	;	- When reading from memory, the value that gets read is placed on the data bus, which carries the 8-bit value to the CPU.
	;	- So in this example of LDA <$00, the value read is $A5, so the data bus holds $A5.
	; 2. Fetch the operand:
	;	- The value of the PC is transferred to the Address Bus, and that address is read. The PC is also incremented.
	;	- In this case, the value read is $00, which sets up the address bus for the third cycle of the LDA zeroPage instruction.
	; 3. Read from target address:
	;	- Read the value determined by the address bus. (in this case, that's address $0000)
	;	- The value at address $0000 is put on the data bus, and the CPU takes this value and overwrites the value of the A Register.
	;	
	; Great! So that's how the data bus works. But what happens if you read from somewhere not mapped to anything?
	; Let's see how LDA $5000 works. This has 4 cycles.
	; 1. Fetch the opcode: (The data bus now holds $AD)
	; 2. Fetch the first operand: (The data bus now holds $00)
	; 3. Fetch the second operand: (The data bus now holds $50)
	; 4. Read from target address:
	;	- Since there's nothing mapped to address $5000, the data bus is left floating, and nothing changes.
	;	- Since the value of the data bus is unchanged, it still holds the value $50, which was set during the third cycle.
	;
	; And that's how open bus works!
	; Open bus is typically from $4000 to $7FFF. (Except for addresses $4015 (APU_STATUS), $4016 (Controller port 1), and $4017 (Controller port 2)
	; If the cartridge has "PRG RAM", which is typically from $6000 to $7FFF, then those addresses wouldn't be open bus since they are mapped to something.
	; This cartridge doesn't have any PRG RAM, but I'm only going to test from the $4000 to $5FFF range.
	; Most emulators assume that (unless specified) the cartridge has PRG RAM from $6000 to $7FFF.
	; I personally think that PRG RAM should not exist by default, but the iNES format would disagree.
	; Therefore this ROM needs to be NES 2.0 just to guarantee the open bus there, assuming the emulator is NES 2.0 compliant.
	; But for simplicity, this ROM isn't using a NES 2.0 header, so I'll just avoid checking that range entirely.
	;
	; anyway, some emulators might just assume reading from this range always returns 00, which is incorrect. Let's test for that!
	LDA $5000
	BEQ TEST_Fail
	LDA $4654
	BEQ TEST_Fail
	INC <ErrorCode 
	
	;;; Test 2 [Open Bus]: Reading from open bus always returns the high byte of the address read. ;;;
	; As explained above, when reading from one of these addresses, the second operand is the value that remains on the data bus.
	; so, reading from $5501 should set A to $55, as the high byte is the most recently read value.	
	LDA $5501
	CMP #$55
	BNE TEST_Fail
	LDA $4018
	CMP #$40
	BNE TEST_Fail
	LDA $5FFF
	CMP #$5F
	BNE TEST_Fail
	INC <ErrorCode
	
	;;; Test 3 [Open Bus]: Indexed addressing crossing a page boundary does not update the data bus. ;;;
	; But the rule of "the high byte is the value returned" isn't always the case.
	; As you can see, using an offset to cross a page boundary will not update the data bus!
	LDY #$10
	LDA $50F8, Y ; This offset changes the high byte of the value read, but not the data bus. (Read from $5108, the value read should be $50)
	CMP #$50
	BNE TEST_Fail
	INC <ErrorCode
	
	;;; Test 4 [Open Bus]: The data bus actually exists, and the open bus behavior isn't being faked. ;;;
	; This is tested by moving the program counter to open bus, and running a very choreographed function.
	; Here is what is expected to run in open bus:
	; LSR <$56, X
	; RTS
	;
	; Here's what could go wrong:
	; Open bus behavior could be faked, specifically by always returning the high byte from this address range.
	; in which case, `LSR <$56, X` will run until $5700, running `SRE <$57, X` until $5800, running `CLI` until $5900, and so on.
	; In that case, once the PC reaches $6000, it will run RTS, however the flags and stuff will be wrong, so we can check for that.
	;	-In theory we already ruled this behavior out with previous tests... but who knows. A lot could go wrong with emulation.
	;
	; It's also possible the same thing will happen, but instead of RTS, it runs BRK. Either way, that's a fail.
	; Since that's a possibility, set up the IRQ routine.
	;
	; It's also possible the JSR instruction does things out of order, leaving the wrong value on the data bus. I can't really predict what will happen then, but just so we're clear:
	; Here are all the cycles of JSR. (Simplified. JSR is actually a super odd instruction. I recommend looking at it in visual 6502 some time.)
	; 1: Read the opcode.
	; 2: Read the first operand.
	; 3: Dummy read from stack.
	; 4: Push PC High to the stack.
	; 5: Push PC Low to the stack.
	; 6: Read the second operand.
	;
	; See [JSR Edge Cases] test 3.

	LDX #0
TEST_OpenBus_PrepIRQLoop:
	LDA TEST_OpenBus_IRQRoutine,X ; TEST_OpenBus_IRQRoutine can be found at the end of this test. It's just a bunch of PLA's and a JMP to TEST_Fail.
	STA $600, X
	INX
	CPX #8
	BNE TEST_OpenBus_PrepIRQLoop
	; and prep for the test:
	LDA #$C0 ; this will get ROR'ed into an RTS instruction... hopefully.
	STA <$56 ; store it in RAM, ready for the test.
	LDX #0	 ; X needs to be zero for this.
	JSR $5600; open bus!
	; We made it back safely
	; if a BRK occurred (possibly at $6000), or if we executed into $8000, we failed.
	LDA <$56
	CMP #$60
	BNE TEST_Fail
	INC <ErrorCode 
	
	;;; Test 5 [Open Bus]: Dummy Reads update the data bus, test by reading $4000 ;;;
	; This doubles as a test of dummy read cycles, and the PPU IO bus. Here's what happens.
	; LDA $3FFF, X (X=$01)
	; 1: fetch opcode 
	; 2: fetch low byte
	; 3: fetch high byte, add the X offset to the low byte
	; 4: READ $3F00, then fix the high byte
	; 5: READ $4000.
	;
	; $3F00 is a mirror of $2000, which returns the PPU IO Bus when read.
	; So we need to set the PPU Bus to something first.
	LDA #0
	STA $2002
	LDX #$01
	; let's run the test.
	LDA $3FFF,X 
	BNE TEST_Fail
	; Let's set the PPU Bus to $FF and run it again!
	LDA #$FF
	STA $2002

	NOP
	NOP ; I need address $A0A0 to be something very specific (in order to prevent an incorrect emulation from crashing), so I'm adding some NOPs here.
	BNE TEST_OpenBus_ContinueTest5 ; Skip to TEST_OpenBus_ContinueTest4
	;; If you are reading this for test 5, just ignore these next few lines. ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
TEST_OpenBusA0A0:              ; This is a fail-safe for test 8. It needed to be at address $A0A0.	         ;;
	SEI						   ; The RTI instruction pulled off some junk and we need to re-set the i flag.  ;;
	LDX #1                     ; X=1, which is used to tell test 8 that it failed.                           ;;
	JMP TEST_OpenBus_PostTest8 ; Jump to the end of test 8.                                                  ;;
TEST_OpenBus_ContinueTest5:    ; Anyway, that was the greatest crime against programming I've ever committed.;;
	;; And now, back to your regularly scheduled program. ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	
	LDA $3FFF,X
	CMP #$FF ; Check if the dummy read set the data bus to $FF.
TEST_Fail_1p5:
	BNE TEST_Fail
	INC <ErrorCode 
	
	;;; Test 6 [Open Bus]: The upper 3 bits when reading from the controller are open bus. ;;;
	; This is just checking to see if the controllers have the open bus bits.
	LDA $4016
	AND #$E0
	CMP #$40 ; When running LDA $4016, bit 6 is likely to be set.
	BNE TEST_Fail_1p5
	LDA $4017
	AND #$E0
	CMP #$40 ; When running LDA $4017, bit 6 is likely to be set.
	BNE TEST_Fail_1p5
	; This doubles as a test of dummy read cycles, and the PPU IO bus.
	LDA #$F0
	STA $2002	; Set the PPU IO bus to $F0
	LDX #$17
	LDA $3FFF, X ; dummy read $2006. (The data bus is now $F0) The offset moves the address bus to $4016, reading from controller 1 when the data bus was $F0.
	AND #$E0
	CMP #$E0 ; However, in this case, the open bus bits are all set.
	BNE TEST_Fail_1p5
	INX		 ; We're going to run a similar trick with controller 2, but instead of dummy reading a mirror of $2006, it will dummy read a mirror of $2007. Let's set up the ppu read buffer.
	JSR WaitForVBlank
	LDA #0
	STA <dontSetPointer
	JSR PrintCHR	; The PrintCHR function will read the 2 byte word, and following bytes up until it reads $FF (a terminator) and then fix the return address such that RTS returns to the byte after the terminator.
	.word $2C00
	.byte $F0, $FF
	; PrintCHR will return here. The .word $2C00 and ,byte $F0, $FF don't get executed.

	JSR SetPPUADDRFromWord
	.byte $2C, $00
	; SetPPUADDRFromWord will return here.
	LDA $2007 ; empty PPU buffer
	LDA $3FFF, X ; dummy read $2007 (The data bus is now $F0) The offset moves the address bus to $4017, reading from controller 2 when the data bus was $F0.
	PHA
	JSR ResetScroll	; And reset the scroll, since we just moved "v" to $2400.
	PLA
	AND #$E0
	CMP #$E0 ; However, in this case, the open bus bits are all set.
	BNE TEST_Fail2
	INC <ErrorCode
	
	;;; Test 7 [Open Bus]: Reading from $4015 does not update the data bus. ;;;
	; Address $4015 is special. All the values read here are internal to the 2A03 chip, so the data bus isn't used. 
	;
	; LDA $40FF, X (X=$16)
	; 1: fetch opcode 
	; 2: fetch low byte
	; 3: fetch high byte, add the X offset to the low byte
	; 4: READ $4015, then fix the high byte
	; 5: READ $4115.
	;
	; The value read from $4015 will be zero, but that does NOT change the data bus!
	; Therefore, the value read from $4115 will still be $40 from when the high byte was fetched.
	LDX #$16
	LDA $40FF,X
	CMP #$40
	BNE TEST_Fail2
	INC <ErrorCode 
	
	;;; Test 8 [Open Bus]: Writing always updates the data bus, even writing to $4015 ;;;
	; LSR <56,X
	; 	$CD >> 1 = $66 + Carry set
	; ROR <$66
	;	$22 >> 1 = $91
	; STA ($91),Y
	; A=60 -> ($15, $40)
	;
	; How could this one go wrong? Well, if writing to $4015 does not update the data bus, this will run RTI instead of RTS.
	; We can prep for this by pushing $A0 to the stack, so if an RTI occurs, we'll return to TEST_OpenBusA0A0
	LDX #0
	LDY #0
	LDA #$CD
	STA <$56 ; $56 = #$CD
	LDA #$22
	STA <$66 ; $66 = #$22
	LDA <$91 ; Push these to the stack
	PHA
	LDA <$92 ; These are important bytes for the test selection menu, so we'll restore these after the test.
	PHA
	LDA #$15
	STA <$91
	LDA #$40
	STA <$92 ; ($91) = $4015
	LDA #$A0
	PHA
	LDA #$60 ; A = the value of RTS
	JSR $5600 ; Jump to open bus to run this!
	; and if we made it back here, the test worked!
	; restore the values from $91 and $92
	PLA ; pull off the $A0 for the RTI guardrails.
TEST_OpenBus_PostTest8:
	PLA
	STA <$92
	PLA
	STA <$91
	TXA ; X = 0 if we ran RTS, X = 1 if we ran RTI.
	CPX #$01
	BEQ TEST_Fail2	
	INC <ErrorCode
	
	;;; Test 9 [Open Bus]: Bit 5 of address $4015 is open bus ;;;
	LDA #$20
	STA $2002
	LDX #$25
	LDA $3FF0, X
	AND #$20
	BEQ TEST_Fail2
	
	;; END OF TEST ;;	
	LDA #1
	RTS
;;;;;;;

TEST_OpenBus_IRQRoutine: 
	; This is used in test 4 when we jump to open bus. If the behavior is inaccurate, a BRK is likely to run.
	; We want to run the following code if a BRK occurs, so this gets copied to the IRQ routine in RAM.
	PLA
	PLA
	PLA
	PLA
	PLA
TEST_Fail2:
	JMP TEST_Fail ; This is part of TEST_OpenBus_IRQRoutine, but I'm re-using this JMP to save bytes.
;;;;;;;
	
TEST_ROMnotWritable:
	;;; Test 1 [ROM is not Writable]: Writing to ROM does nothing. ;;;
	; This is an NROM cartridge, so there aren't banks to swap or anything
	LDA #$06 ; 06 = FAIL
	STA CannotWriteToROM_01 ; This address holds a $01
	LDA CannotWriteToROM_01 ; If ROM was updated, you read a 2, which fails the test.
	;; END OF TEST ;;
	RTS						; else, return 1, thus passing.
;;;;;;;

TEST_PPURegMirroring:
	;;; Test 1 [PPU Register Mirroring]: PPU Registers are mirrored through $3FFF ;;;
	; The registers from $2000 to $2007 get repeated every 8 bytes.
	; I'm only testing mirrors of PPUADDR and PPUDATA, but surely if those are implemented, the rest are too.
	LDX #$28     ; Move the PPU v register to $2800
	STX $2006+8  ; A mirror of PPUADDR
	LDY #$00
	STY $2006+16 
	LDA #$01
	STA $2007+32 ; A mirror of PPUDATA
	STX $2006+64 ; Move the PPU v register back to $2800
	STY $2006+128
	LDA $2007+256; Read the buffer
	LDA $3FFF    ; Read the value at VRAM $2800
	PHA	         ; Push the results to the stack
	STX $2006    ; The test has already concluded, so let's not bother with mirrors.
	STY $2006    ; Clear that value back to a $24
	LDA #$24
	STA $2007
	JSR ResetScroll
	PLA          ; Pull the results off the stack
	CMP #$01
	BNE TEST_Fail2
	INC <ErrorCode
	;; END OF TEST ;;
	RTS
;;;;;;;;;;;;;;;;;;

TEST_DummyReads:
	; Pre-Test preparations.
	LDA #$20
	STA <$51
	LDA #$02
	STA <$50 ; ($50) points to $2002
	LDA #$3F
	STA <$53
	LDA #$F0
	STA <$52 ; ($52) points to $3FF0
	
	;;; Test 1 [Dummy Read Cycles]: A mirror of PPU_STATUS ($2002) will be read twice by LDA $20F2, X (where X = $10). ;;;
	; Since reading $2002 clears bit 7 of PPUSTATUS, we can check if dummy reads are happening by running dummy reads on $2002, then checking bit 7.
	; Let's walk through the LDA $20F2, X instruction cycle by cycle, where X = $10
	; 1: fetch opcode 
	; 2: fetch low byte
	; 3: fetch high byte, add the X offset to the low byte
	; 4: Read $2002, if adding the offset crosses a page boundary (in this case it did), update the high byte.
	; 5: Read $2102.
	;
	; Focus on cycle 4. That's the dummy read.
	
	LDX #$10
	JSR Clockslide_PALFrame ; Wait a frame so the VBlank flag (bit 7) gets set
	LDA $20F2, X ; If bit 7 of A gets set, then $2002 was only read once.
	BMI TEST_Fail2
	INC <ErrorCode 
	
	;;; Test 2 [Dummy Read Cycles]: The dummy read does NOT occur if a page boundary is not crossed ;;;	
	LDX #0
	JSR Clockslide_PALFrame ; Wait a frame so the VBlank flag (bit 7) gets set
	LDA $2002, X ; The page boundary is not crossed, so there should only have been 1 read.
TEST_DummyReads_BPLFail: ; I ran out of bytes so the branches here are a bit cursed.
	BPL TEST_Fail2
	INC <ErrorCode 
	
	;;; Test 3 [Dummy Read Cycles]: The dummy read is on the correct address ;;;	
	; The dummy read happens after the low byte is updated, but before the high byte.
	LDX #$62
	JSR Clockslide_PALFrame ; Wait a frame so the VBlank flag gets set
	LDA $3FF0, X ; Dummy read $3F52 (A mirror of $2002), then read $4052 (Open bus emulation is NOT needed to pass this test!)
	LDA $2002	 ; If bit 7 of A gets set, then the dummy read was from the wrong address (bit 7 of $2002 was not cleared by the dummy read).
TEST_DummyReads_BMIFail: ; I ran out of bytes so the branches here are a bit cursed.
	BPL TEST_DummyReads_BMIFail_OK
	JMP TEST_Fail2
TEST_DummyReads_BMIFail_OK:
	INC <ErrorCode 	
	
	;;; Test 4 [Dummy Read Cycles]: STA $2002, X (where X=0) reads $2002 once. ;;;
	LDX #0
	JSR Clockslide_PALFrame ; Wait a frame so the VBlank flag gets set
	STA $2002, X ; The dummy read cycle will read from $2002.
	LDA $2002	 ; If bit 7 of A gets set, then $2002 was not read during the STA
	BPL TEST_DummyReads_Test4OK
	JMP TEST_Fail2
TEST_DummyReads_Test4OK:
	INC <ErrorCode 	
	
	;;; Test 5 [Dummy Read Cycles]: STA dummy read is on the correct address ;;;
	LDX #$62
	JSR Clockslide_PALFrame ; Wait a PAL frame so the VBlank flag gets set
	STA $3FF0, X ; The dummy read cycle will read from $2002.
	LDA $2002	 ; If bit 7 of A gets set, then $2002 was not read during the STA
	BMI TEST_DummyReads_BMIFail
	INC <ErrorCode 	

	;;; Test 6 [Dummy Read Cycles]: LDA ($2002),Y (where Y=3) does not have a dummy read. ;;;
	; The page boundary isn't crossed, so no dummy read.
	LDY #1

	JSR Clockslide_PALFrame ; Wait a PAL frame so the VBlank flag gets set
	LDA [$0050],Y  ; The dummy read does NOT happen because a page boundary was not crossed.
	LDA $2002 ; The dummy read didn't occur, so bit 7 should be set.
TEST_DummyReads_BPLFail2:
	BPL TEST_DummyReads_BPLFail 
	INC <ErrorCode 	
	
	;;; Test 7 [Dummy Read Cycles]: LDA ($3FF0),Y (where Y=62) dummy read occurs, and is on the correct address ;;;
	LDY #$62
	JSR Clockslide_PALFrame ; Wait a PAL frame so the VBlank flag gets set
	LDA [$0052],Y
	LDA $2002	 ; If bit 7 of A gets set, then $2002 was not read during the LDA
	BMI TEST_DummyReads_BMIFail
	INC <ErrorCode 
	
	;;; Test 8 [Dummy Read Cycles]: STA ($2002),Y (where Y=1) does not have a dummy read. ;;;
	; The page boundary isn't crossed, so no dummy read.
	LDY #1
	JSR Clockslide_PALFrame ; Wait a PAL frame so the VBlank flag gets set
	STA [$0050],Y
	LDA $2002	 ; The dummy read didn't occur, so bit 7 should be set.
	BPL TEST_DummyReads_BPLFail
	INC <ErrorCode 
	
	;;; Test 9 [Dummy Read Cycles]: STA ($3FF0),Y (where Y=62) dummy read is on the correct address ;;;
	LDY #$62
	JSR Clockslide_PALFrame ; Wait a PAL frame so the VBlank flag gets set
	STA [$0052],Y
	LDA $2002	 ; If bit 7 of A gets set, then $2002 was not read during the STA
	BMI TEST_DummyReads_BMIFail
	INC <ErrorCode 
	
	;;; Test A [Dummy Read Cycles]: LDA ($2002,X) does not dummy-read $2002 ;;;
	LDX #0
	JSR Clockslide_PALFrame ; Wait a PAL frame so the VBlank flag gets set
	LDA [$50,X]
	BPL TEST_DummyReads_BPLFail2 ; If bit 7 of A is set, then we pass the test. The dummy read was at $0050, which we can't test for.
	INC <ErrorCode 	
	
	;;; Test B [Dummy Read Cycles]: STA ($2002,X) does not dummy-read $2002 ;;;
	LDX #0
	JSR Clockslide_PALFrame ; Wait a frame so the VBlank flag gets set
	STA [$50,X]
	LDA $2002	 ; If bit 7 of A gets set, then $2002 was not read during the STA
	BPL TEST_DummyReads_BPLFail2 ; If bit 7 of A is set, then we pass the test. The dummy read was at $0050, which we can't test for.	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_FailPPUOpenBus:
	JSR ResetScroll
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_PPU_IO_Open_Bus:
	;;; Test 1 [PPU IO Register Open Bus]: Verify PPU IO Open Bus exists. ;;;
	; Don't worry, this this is remarkably simple.
	; Here's how PPU IO Open bus works.
	; The PPU IO bus is updated whenever the CPU writes to any PPU Register.

	JSR OAMDMAWithPage2
	
	LDX #0
	LDY #1
	LDA #$5A
	STA $2002 ; Address $2002 is read-only. This puts $5A on the ppu bus.
	TXA	  ; clear A for the test.
	LDA $2000 ; Address $2000 is write-only, so the value read is the value of the PPU bus. ($5A)
	CMP #$5A
	BNE TEST_FailPPUOpenBus
	INC <ErrorCode 
	
	;;; Test 2 [PPU IO Register Open Bus]: All PPU Registers update PPU IO Open Bus. ;;;
	; Writing to $2000 updates the PPU IO bus
	LDA <PPUCTRL_COPY
	STA $2000 ; this updates the PPU bus and changes nothing with the register... hopefully.
	TXA
	LDA $2001 ; read a different write-only register.
	CMP <PPUCTRL_COPY
	BNE TEST_FailPPUOpenBus
	
	; Writing to $2001 updates the PPU IO bus
	LDA <PPUMASK_COPY
	STA $2001
	TXA
	LDA $2000
	CMP <PPUMASK_COPY
	BNE TEST_FailPPUOpenBus

	; we've already tested writing to $2002
	
	; Writing to $2003 updates the PPU IO bus
	LDA #04
	STA $2003
	TXA
	LDA $2000
	CMP #04
	BNE TEST_FailPPUOpenBus
	
	; Writing to $2004 updates the PPU IO bus
	LDA #$FF
	STA $2004
	TXA
	LDA $2000
	CMP #$FF
	BNE TEST_FailPPUOpenBus
	
	; Writing to $2005 updates the PPU IO bus
	LDA $2002
	LDA #$00
	STA $2005
	TYA
	LDA $2000
	CMP #$00
	BNE TEST_FailPPUOpenBus
	
	; Writing to $2006 updates the PPU IO bus
	LDA $2002
	LDA #$20
	STA $2006
	TXA
	LDA $2000
	CMP #$20
	BNE TEST_FailPPUOpenBus
	
	; Writing to $2007 updates the PPU IO bus
	LDA #$24
	STA $2007
	TYA
	LDA $2000
	CMP #$24
	BNE TEST_FailPPUOpenBus2
	INC <ErrorCode 
	
	;;; Test 3 [PPU IO Register Open Bus]: Address $2002, bits 0 through 4 are open bus ;;;
	LDA $2002                ; reset the ppu's w latch. (not entirely needed, but good practice to do this before a write to $2006)
	LDA #$15                 ; A = $15
	STA $2006                ; The ppu IO bus is now $15 (%0001 1001)
	LDA $2002                ; reading from $2002 only affects the upper 3 bits of the ppu IO bus, so you will see the previous contents of bits 0 through 4. (%xxx1 1001)
	AND #$1F                 ; Mask away the upper 3 bits. (%0001 1001)
	CMP #$15                 ; Since reading from $2002 gives you the ppu's IO open bus data for bits 0 through 4, we should see that A = $15.
	BNE TEST_FailPPUOpenBus2 ; Otherwise, fail the test.
	INC <ErrorCode 
	JSR ResetScroll
	
	;;; Test 4 [PPU IO Register Open Bus]: The upper 3 bits of the PPU IO bus is updated by reads of $2002. ;;;
	JSR WaitForVBlank        ; this clears the vblank flag.
	LDA #$FF                 ; A = $FF
	STA $2002                ; The ppu IO bus = $FF
	LDA $2002                ; Reading $2002 only updates the upper 3 bits of the ppu IO open bus. (the upper 3 bits are all zero in this instance)
	LDA $2000                ; Read a write-only register to get the ppu IO open bus value. (%0001 1111)
	CMP #$1F                 ; Check if A = $1F.
	BNE TEST_FailPPUOpenBus2 ; Otherwise, fail the test.

	LDA <$50	; This value will be $00 if you are running [PPU IO Register Open Bus], but $01 if you are running [Dummy Write Cycles], which re-runs this test to verify the ppu bus works as a prerequisite.
	            ; We don't need to check if the ppu IO open bus decays for that test, so we can skip that.
	BNE TEST_PPU_Open_Bus_SkipDecayTest
	INC <ErrorCode 

	
	;;; Test 5 [PPU IO Register Open Bus]: The PPU IO bus decays. ;;;
	; Since having bits decay is analogue behavior, you're probably going to need to "fake" this.
	; To make a long story short, if nothing updates the PPU IO bus, then the bits *eventually* decay to 0's.
	; Emphasis on *eventually* because that's the inconsistent part on real hardware.
	; There's no "logic" determining how long the bits should persist before decaying on real hardware, and this test is known to fail on hardware briefly after powering on the console.
	; - The bits tend to decay faster the warmer the PPU is, though I'm not checking for that here.
	; There's multiple ways to emulate this behavior, but I recommend making your implementation deterministic, rather than throwing random numbers around. (or at least make the RNG seeded?)
	;
	; I think the simplest approach is to give each bit of the ppu IO bus an integer that ticks down every ppu cycle.
	; Then whenever any bits of the ppu IO bus are updated, you initialize the integer for that bit with *some constant* (or add randomness if you prefer.)
	; - since this is analogue behavior, there is no "canonical" value for what you should initialize the integer with, though I recommend it takes somewhere between 5 and 30 frames to hit 0.
	LDA #$FF
	STA $2002                           ; Load the ppu IO bus with $FF. (all bits set.)
	LDX #120                            ; X = 120
TEST_PPU_Open_Bus_120FrameStall:        ; wait approximately two seconds.
	JSR Clockslide_PALFrame	            ; stall for approximately 1 frame.
	DEX                                 ; Decrement X
	BNE TEST_PPU_Open_Bus_120FrameStall ; Loop until X = 0;
	LDA $2000                           ; Read a write-only register to get the ppu IO open bus value. It should be all zeroes, as there was more than enough time for all the bits to decay.
	BNE TEST_FailPPUOpenBus2            ; If any bits are still set, fail the test.

	;; END OF TEST ;;
TEST_PPU_Open_Bus_SkipDecayTest:
	JSR WaitForVBlank
	JSR ResetScroll
	LDA #01
	RTS
;;;;;;;
TEST_FailPPUOpenBus2:
	JSR ResetScroll
	JMP TEST_Fail

TEST_DummyWritePrep_PPUADDR2DFA: ; This exists to save bytes
	JSR SetPPUADDRFromWord
	.byte $2D, $FA
	LDA #$2D
	STA $2002 ; Set the PPU IO bus value to 2D
	RTS
;;;;;;;

TEST_DummyWritePrep_2E: ; This exists to save bytes
	JSR TEST_DummyWritePrep_PPUADDR2DFA ; just leech off this to save bytes.
	LDA #$2E
	STA $2002 ; Set the PPU IO bus value to 26
	RTS
;;;;;;;

TEST_DummyWrites:
	; Special thanks to bisqwit and blargg for creating a test for dummy writes. (I'm pretty much just doing what they did.)
	; Consider the ASL instruction.
	; This is a "Read-Modify-Write" instruction, for it does the following:
	; Read target address, modify the value, and write it back.
	; But that's not the whole story, as this instruction has "Dummy Writes". (Indexed instructions also have dummy reads in addition to dummy writes)
	; Consider ASL $0400. Let's see every cycle of this instruction.
	; 1: fetch opcode 
	; 2: fetch low byte
	; 3: fetch high byte
	; 4: Read $0400.
	; 5: Write the value back to $0400, then do the operation on this value. (arithmetic shift left)
	; 6: Write this new value to $0400.
	;
	; Focus on cycle 5. That's the dummy write.
	
	;;; Test 1 [Dummy Write Cycles]: Verify PPU IO Open Bus exists. ;;;
	; This Dummy Write test relies on PPU IO Open Bus, so if it's not emulated we cannot check for dummy writes accurately.
	LDA #1
	STA <$50				; The PPU_Open_Bus test uses address $50 to skip the decay test, since that's not needed here.
	JSR TEST_PPU_IO_Open_Bus; It feels pretty silly running another test inside this test.
	LDX #1					; But hey, it saves on bytes.
	STX <ErrorCode		; reset the current sub test, as running TEST_PPU_Open_Bus changed it.
	CMP #$01				
	BNE TEST_FailPPUOpenBus2
	INC <ErrorCode 
	
	; Here's how the test works.
	; Prep the PPU IO bus with a specific value, usually $2D or $2E.
	; RMW $2006. Read $2006 (PPU IO open bus), Dummy Write $2006 and modify value read, write $2006 again.
	; If we know where the writes will take the 'v' register, then we can simply read $2007 twice after this test to verify the dummy writes occurred.
	
	; for example: INC $2006
	; 1: fetch opcode 
	; 2: fetch low byte
	; 3: fetch high byte
	; 4: Read $2006. (address $2006 is write-only, so we read the PPU IO bus: #$2D)
	; 5: Write #$2D to $2006, then do the operation on this value. (INC #$2D = #$2E)
	; 6: Write #$2E to $2006. The VRAM address is now $2D26	
	
	; Let's make some preparations...
	JSR ResetScrollAndWaitForVBlank
	
	; Let me explain this subroutine real quick.
	; The return address is modified inside this subroutine, so it returns to the byte after the terminator.
	; Basically, WriteToPPUADDRWithByte will read the two bytes after it, and store them to $2006, then the third byte is stored at $2007.
	; Then, if the following byte if $FF (the terminator), exit the subroutine. Otherwise, grab the next 3 bytes and do it again.
	JSR WriteToPPUADDRWithByte
	.byte $2D, $5A, $60 ; VRAM[$2D5A] = $5A
	.byte $2D, $5B, $5C ; VRAM[$2D5B] = $5C
	.byte $2D, $16, $F1 ; VRAM[$2D16] = $F1
	.byte $2D, $96, $7E ; VRAM[$2D96] = $7E
	.byte $2D, $2C, $11 ; VRAM[$2D2C] = $11
	.byte $2D, $2E, $22 ; VRAM[$2D2E] = $22
	
	.byte $2E, $5C, $8D ; VRAM[$2E5C] = $8D
	.byte $2E, $5D, $A5 ; VRAM[$2E5D] = $A5
	.byte $2E, $17, $F0 ; VRAM[$2E17] = $F0
	.byte $2E, $97, $36 ; VRAM[$2E97] = $36
	.byte $2E, $2D, $98 ; VRAM[$2E25] = $98
	.byte $2E, $2F, $4F ; VRAM[$2E27] = $4F
	.byte $FF ; Terminator.
	; WriteToPPUADDRWithByte will return here:
	JSR ResetScrollAndWaitForVBlank

	;;; Test 2 [Dummy Write Cycles]: See if Read-Modify-Write instructions write to $2006 twice. ;;;
	JSR TEST_DummyWritePrep_PPUADDR2DFA ; v = 2DFA, PpuBus = $2D
	ASL $2006							; v = 2D5A
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$60
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_PPUADDR2DFA ; v = 2DFA, PpuBus = $2D
	SEC
	ROL $2006							; v = 2D5B
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$5C
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_PPUADDR2DFA ; v = 2DFA, PpuBus = $2D
	LSR $2006							; v = 2D16
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$F1
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_PPUADDR2DFA ; v = 2DFA, PpuBus = $2D
	SEC
	ROR $2006							; v = 2D96
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$7E
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_PPUADDR2DFA ; v = 2DFA, PpuBus = $2D
	DEC $2006							; v = 2D2C
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$11 ;
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_PPUADDR2DFA ; v = 2DFA, PpuBus = $2D
	INC $2006							; v = 2D2E
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$22 ;
	BNE TEST_FailDummyWrites
	INC <ErrorCode 
	JMP TEST_DummyWritesPt2
;;;;;;;
TEST_FailDummyWrites:
	JSR ResetScroll
	JMP TEST_Fail
TEST_DummyWritesPt2:
	JSR ResetScrollAndWaitForVBlank
	;;; Test 3 [Dummy Write Cycles]: See if Read-Modify-Write instructions with X indexing write to $2006 twice. ;;;
	LDX #6
	JSR TEST_DummyWritePrep_2E ; v = 2DFA, PpuBus = $2E
	ASL $2000,X			       ; v = 2E4C
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$8D
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_2E ; v = 2DFA, PpuBus = $2E
	SEC
	ROL $2000,X			       ; v = 2E4D
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$A5
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_2E ; v = 2DFA, PpuBus = $2E
	LSR $2000,X			       ; v = 2E13
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$F0
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_2E ; v = 2DFA, PpuBus = $2E
	SEC
	ROR $2000,X			       ; v = 2E93
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$36
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_2E ; v = 2DFA, PpuBus = $2E
	DEC $2000,X			       ; v = 2E25
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$98 ;
	BNE TEST_FailDummyWrites
	
	JSR TEST_DummyWritePrep_2E ; v = 2DFA, PpuBus = $2E
	INC $2000,X			       ; v = 2E27
	JSR DoubleLDA2007 ; Read from VRAM
	CMP #$4F ;
	BNE TEST_FailDummyWrites
	
	;; END OF TEST ;;
	JSR ResetScroll
	LDA #01
	RTS
;;;;;;;

RTS_If_Running_All_Tests:	; The following tests should not draw anything on screen if we're running the automatically-run-all-tests mode.
	LDA <RunningAllTests
	BEQ RTS_If_Running_All_Tests_Continue ; skip printing stuff on screen if we're running all tests right now.
	PLA
	PLA
	LDA #01
	RTS
RTS_If_Running_All_Tests_Continue:
	RTS
;;;;;;;

TEST_PowerOnState_CPU_RAM:
	;;; Test 1 [CPU RAM Power On State]: Print the values recorded at power on ;;;
	JSR RTS_If_Running_All_Tests ; If running all tests automatically, skip drawing stuff on screen. This isn't actually testing anything anyway.
	JSR ClearNametableFrom2240
	JSR ResetScrollAndWaitForVBlank
	JSR Print32Bytes
	.word $2244
	.word PowerOnRAM
	JSR ResetScroll
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;	

TEST_PowerOnState_PPU_RAM:
	;;; Test 1 [PPU RAM Power On State]: Print the values recorded at power on ;;;
	JSR RTS_If_Running_All_Tests ; If running all tests automatically, skip drawing stuff on screen. This isn't actually testing anything anyway.
	JSR ClearNametableFrom2240
	JSR ResetScrollAndWaitForVBlank
	JSR Print32Bytes
	.word $2244
	.word PowerOnVRAM
	JSR ResetScroll
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;	

TEST_PowerOnState_PPU_Palette:
	;;; Test 1 [Palette RAM Power On State]: Print the values recorded at power on ;;;
	JSR RTS_If_Running_All_Tests ; If running all tests automatically, skip drawing stuff on screen. This isn't actually testing anything anyway.
	JSR ClearNametableFrom2240
	JSR ResetScrollAndWaitForVBlank
	JSR Print32Bytes
	.word $2244
	.word PowerOnPalette
	JSR ResetScroll
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;	

TEST_PowerOnState_PPU_ResetFlag:
	;;; Test 1 [PPU Reset Flag]: Print the value recorded at power on ;;;
	JSR ClearNametableFrom2240

	LDA PowerOnTest_PPUReset
	CMP #1
	BNE TEST_PowerOnState_PPU_Res_No

	JSR PrintTextCentered
	.word $2252
	.byte "Reset Flag Detected!", $FF
	JSR ResetScroll
	RTS
	
TEST_PowerOnState_PPU_Res_No:
	JSR PrintText
	.word $2245
	.byte "No Reset Flag Detected!", $FF
	JSR ResetScroll
	RTS
;;;;;;;

TEST_PowerOnState_CPU_Registers:
	;;; Test 1 [CPU Registers Power On State]: Print the values recorded at power on ;;;
	
	; This is a DRAW test (not pass/fail), and it does not run in the all-test mode.
	
	JSR ClearNametableFrom2240
	JSR ResetScrollAndWaitForVBlank
	LDA #0
	STA <dontSetPointer
	
	JSR PrintText
	.word $2252
	.byte "A ", $FF
	LDA PowerOn_A
	JSR PrintByte
	
	JSR PrintText
	.word $2272
	.byte "X ", $FF
	LDA PowerOn_X
	JSR PrintByte
	
	JSR PrintText
	.word $2292
	.byte "Y ", $FF
	LDA PowerOn_Y
	JSR PrintByte

	JSR ResetScrollAndWaitForVBlank

	JSR PrintText
	.word $22A6
	.byte "Stack Pointer ", $FF
	LDA PowerOn_SP
	JSR PrintByte
	
	JSR PrintText
	.word $22C4
	.byte "Processor flags ", $FF
	LDA PowerOn_P
	JSR PrintByte
	JSR ResetScroll

	;; END OF TEST ;;
	LDA #1 
	RTS
;;;;;;;

; These upcoming subroutines are used in the individual opcode tests for the unofficial instructions.

TEST_VerifyInstructionIsTwoByte: ; Write the following to address $5C0: [opcode] $C8, $60
	LDA <Copy_A ; the opcode
	STA $5C0
	LDA #Reserved_C8	; It's just the value $C8
	STA $5C1
	LDA #$60
	STA $5C2
	LDA #$50
	STA <Reserved_C8
	STA <Reserved_C8+1
	LDX #0
	LDY #0
	JSR $5C0
	CPY #0
	BNE FAIL_WrongInstructionSize
	LDA <Copy_A ; the opcode
	RTS
;;;;;;;
	
TEST_VerifyInstructionIsThreeByte: ; Write the following to address $5C0: TXS, STX $7FF, LDX #0, [opcode], INY, INY, LDX $7FF, TXS, RTS. If those INY instructions get executed, the instruction was the wrong size. 
	LDX #0
TEST_VerifyInstructionIsThreeLoop:
	LDA TEST_UnOp_ThreeByte_RamFunc, X
	STA $5C0,X
	INX
	CPX #$E
	BNE TEST_VerifyInstructionIsThreeLoop
	LDA <Copy_A ; the opcode
	STA $5C6
	LDA #$50
	STA <Reserved_C8
	STA <Reserved_C8+1
	LDX #0
	LDY #0
	JSR $5C0
	CPY #0
	BNE FAIL_WrongInstructionSize
	LDA <Copy_A ; the opcode
	RTS
;;;;;;;

FAIL_WrongInstructionSize:	; We need to pull 4 different return addresses off the stack.
	LDX #8
	PLA
	DEX
	BNE FAIL_WrongInstructionSize+2
	LDA #2	; Error code 0.
	RTS

TEST_UnOp_ThreeByte_RamFunc:
	TSX
	STX $7FF
	LDX #0
	NOP
	INY
	INY
	LDX $7FF
	TXS
	RTS
;;;;;;


TEST_UnOp_RamFunc: ; this gets copy/pasted into RAM at address $0580
	NOP	; These can be replaced with a JSR instruction.
	NOP	; Certain operations have different behavior if a DMA occurs in the 2nd to last cycle.
	NOP	; So those instructions might put a JSR here to set things up and precisely time time a DMA. 
	LDY <Test_UnOp_Y
	TSX			; Some unofficial instructions modify the stack pointer
	STX <Copy_SP; make a copy of the stack pointer
	LDX <Test_UnOp_SP
	TXS	
	LDX <Copy_X ; restore X for the test.
	LDA <Test_UnOp_FlagsInit
	PHA
	LDA <Test_UnOp_A	
	PLP	; Get initial flags ready for the test.
TEST_UnOp_RamFuncTest: ; Ram Function TEST
	NOP	; Overwrite this with the test.
	NOP	; Overwrite this with the test.
	NOP	; Overwrite this with the test.
	PHA
	PHP	; push the flags from the test
	PLA ; Pull the status flags off into A
	AND #$CF ; mask away the B and T flag, which is set by PHP
	STA <Copy_Flags	; and store the flags here for later
	PLA
	STA <Copy_A  ; Store A
	STX <Copy_X	 ; Store X
	TSX
	STX <Copy_SP2; Store Stack Pointer
	STY <Copy_Y	 ; Store Y
	LDX <Copy_SP; Fix the stack pointer in case it was modified.
	TXS
	LDX <Copy_X ; restore X for the test results.
	RTS
TEST_UnOp_RamFuncEnd:
;;;;;;;;;;;;;;;;;;;;;
; It's a bit cursed to be creating constants here, but labels need to be defined before you can use them to create constants.
UnOpTest_Opcode = $0580+(TEST_UnOp_RamFuncTest-TEST_UnOp_RamFunc)
UnOpTest_Operand = UnOpTest_Opcode+1
UnOpTest_Operand2 = UnOpTest_Opcode+2
;;;;;;;	
TEST_UnOp_Setup:
	; The tests of the Unofficial Instructions will be using this function to set everything up.
	; Copy/Paste the test function into RAM.
	PHA
	LDX #0
TEST_UnOp_SetupLoop:
	LDA TEST_UnOp_RamFunc, X
	STA $580, X
	INX
	CPX #(TEST_UnOp_RamFuncEnd-TEST_UnOp_RamFunc)
	BNE TEST_UnOp_SetupLoop
	PLA
	STA UnOpTest_Opcode
	RTS
;;;;;;;
TEST_UnOp_SetupByAddressingMode:
	; Setting up RAM for the test!
	; The goal: around address $580, we have the code to run the test, but the operands are currently EA EA
	; This function will determine the addressing mode of the test based on the value of the opcode (The A Register)
	; Then a jump table is used to set up the operands of the test around $580.
	; For instance, if you want to test LDA $0500, it will jump to TEST_UnOp_SetupAddressingMode_Absolute
	; ... where the values $00 and $05 will be stored in the operands of the test.
	; Suppose the test is LDA $0500, X. The value stored will be ($0500-X) so the X offset would reach the correct byte. 
	; For zero page instructions, the second operand byte is intentionally left as a NOP.
	;
	; NOTE: These tests assume you have correct implementation of the various addressing modes.
	; In other words, the (indirect), Y tests will always use the exact same operands (always using Test_UnOp_IndirectPointerLo)
	; And the offset for (indirect, X)  test will always land on Test_UnOp_IndirectPointerLo
	
	STA <$FF
	STX <$FD
	; Determine the addressing mode of this instruction by examining the lower 6 bits.	
	; Assume A is the opcode
	STA <$02 ; 2 = opcode
	; get lower 5 bits.
	AND #$1F
	; store this in a temp location
	STA <$03 ; 3 = lower 5 bits of opcode.
	; check if we need to flip from an X offset to a Y offset;
	AND #$17
	CMP #$17
	BNE Test_UnOp_DontFlipXtoY
	LDA <$02 ; A = opcode
	AND #$C0 ; A = upper 2 bits of opcode
	CMP #$80 ; ; if only bit 7 is set, flip X to Y
	BNE Test_UnOp_DontFlipXtoY
	LDA <$03
	AND #$1E
	STA <$03	
Test_UnOp_DontFlipXtoY:
	LDA <$03
	ASL A
	TAX
	LDA Test_UnOp_SetupJumpTable,X
	STA <$0
	LDA Test_UnOp_SetupJumpTable+1,X
	STA <$1
	LDA <$FF
	LDX <$FD
	JMP [$0000]
	
Test_UnOp_SetupJumpTable:
	.word TEST_UnOp_SetupAddrMode_Immediate  ; 0 - Immediate
	.word TEST_Fail							 ; 1 - N/A
	.word TEST_UnOp_SetupAddrMode_Immediate  ; 2 - Immediate
	.word TEST_UnOp_SetupAddrMode_IndX  	 ; 3 - (Indirect, X)
	.word TEST_UnOp_SetupAddrMode_ZP 		 ; 4 - ZeroPage
	.word TEST_Fail							 ; 5 - N/A
	.word TEST_Fail							 ; 6 - N/A
	.word TEST_UnOp_SetupAddrMode_ZP 		 ; 7 - ZeroPage
	.word TEST_Fail							 ; 8 - N/A
	.word TEST_UnOp_SetupAddrMode_Immediate  ; 9 - Immediate
	.word TEST_Fail							 ; A - N/A
	.word TEST_UnOp_SetupAddrMode_Immediate  ; B - Immediate
	.word TEST_UnOp_SetupAddrMode_Abs  		 ; C - Absolute
	.word TEST_Fail							 ; D - N/A
	.word TEST_Fail							 ; E - N/A
	.word TEST_UnOp_SetupAddrMode_Abs  		 ; F - Absolute
	.word TEST_Fail							 ; 10- N/A
	.word TEST_Fail							 ; 11- N/A
	.word TEST_Fail							 ; 12- N/A (HLT is tested elsewhere)
	.word TEST_UnOp_SetupAddrMode_IndY  	 ; 13- (Indirect), Y
	.word TEST_UnOp_SetupAddrMode_ZPX		 ; 14- ZeroPage, X
	.word TEST_Fail							 ; 15- N/A
	.word TEST_UnOp_SetupAddrMode_ZPY		 ; 16- ZeroPage, Y !! Not always the case for the official instructions, but it's convenient for this jump table.
	.word TEST_UnOp_SetupAddrMode_ZPX		 ; 17- ZeroPage, X (or Y if bit 7 is set and bit 6 is not)
	.word TEST_Fail							 ; 18- N/A
	.word TEST_Fail							 ; 19- N/A
	.word TEST_UnOp_SetupAddrMode_Implied    ; 1A- Implied
	.word TEST_UnOp_SetupAddrMode_AbsY 		 ; 1B- Absolute, Y
	.word TEST_UnOp_SetupAddrMode_AbsX 		 ; 1C- Absolute, X
	.word TEST_Fail							 ; 1D- N/A
	.word TEST_UnOp_SetupAddrMode_AbsY 		 ; 1E- Absolute, Y !! Not always the case for the official instructions, but we don't care about that here.
	.word TEST_UnOp_SetupAddrMode_AbsX 		 ; 1F- Absolute, X (or Y if bit 7 is set and bit 6 is not)


TEST_UnOp_SetupAddrMode_Implied:
	; I don't think there are any implied unofficial instructions, so uh... I guess we'll just ignore this label.

TEST_UnOp_SetupAddrMode_Immediate:
	LDA Test_UnOp_ValueAtAddressForTest	; Load the operand of the immediate instruction
	STA UnOpTest_Operand				; and store it in RAM 1 byte after where we stored the opcode.
	JSR TEST_VerifyInstructionIsTwoByte ; Also verify the length of the instruction.
	RTS

TEST_UnOp_SetupAddrMode_IndX:
	STX <Copy_X
	LDA #Test_UnOp_IndirectPointerLo
	SEC
	SBC <Copy_X
	STA UnOpTest_Operand
	LDA <Test_UnOp_OperandTargetAddrHi
	STA <Test_UnOp_IndirectPointerHi
	LDA <Test_UnOp_OperandTargetAddrLo
	STA <Test_UnOp_IndirectPointerLo
	LDA <Test_UnOp_ValueAtAddressForTest
	LDY #0
	STA [Test_UnOp_ExpectedResultAddrLo],Y
	LDY <Copy_Y
	JSR TEST_VerifyInstructionIsTwoByte
	RTS

TEST_UnOp_SetupAddrMode_IndY:
	;;; Set up the test for (Indirect), Y addressed ;;;
	LDA #Test_UnOp_IndirectPointerLo
	STA UnOpTest_Operand	
	STY <Copy_Y
	LDA <Test_UnOp_OperandTargetAddrHi
	STA <Test_UnOp_IndirectPointerHi
	LDA <Test_UnOp_OperandTargetAddrLo
	SEC
	SBC <Copy_Y	
	STA Test_UnOp_IndirectPointerLo
	BCS TEST_UnOp_IndY_DontDecHigh
	DEC <Test_UnOp_IndirectPointerHi
TEST_UnOp_IndY_DontDecHigh	
	LDA <Test_UnOp_ValueAtAddressForTest
	LDY #0
	STA [Test_UnOp_ExpectedResultAddrLo],Y
	LDY <Copy_Y
	JSR TEST_VerifyInstructionIsTwoByte
	RTS

TEST_UnOp_SetupAddrMode_ZP:
	;;; Set up the test for Zero Page addressed ;;;
	LDA <Test_UnOp_OperandTargetAddrLo
	; Only ever test from $50 to $5F
	AND #$0F
	ORA #$50
	STA UnOpTest_Operand
	STA <Test_UnOp_ExpectedResultAddrLo; Modify the pointers
	STA <Test_UnOp_OperandTargetAddrLo ; Modify the pointers
	LDA #0
	STA <Test_UnOp_ExpectedResultAddrHi; Modify the pointers
	STA <Test_UnOp_OperandTargetAddrHi; Modify the pointers
	LDA <Test_UnOp_ValueAtAddressForTest; Load the initial value for the test.
	STY <Copy_Y
	LDY #0
	STA [Test_UnOp_OperandTargetAddrLo],Y
	STA [Test_UnOp_ExpectedResultAddrLo],Y
	LDY <Copy_Y
	JSR TEST_VerifyInstructionIsTwoByte
	RTS

TEST_UnOp_SetupAddrMode_ZPX:
	;;; Set up the test for Zero Page addressed ;;;
	STX <Copy_X
	LDA <Test_UnOp_OperandTargetAddrLo
	; Only ever test from $50 to $5F
	AND #$0F
	ORA #$50
	STA <Test_UnOp_ExpectedResultAddrLo; Modify the pointers
	SEC
	SBC <Copy_X	
	STA UnOpTest_Operand
	STA <Test_UnOp_OperandTargetAddrLo ; Modify the pointers
	LDA #0
	STA <Test_UnOp_ExpectedResultAddrHi; Modify the pointers
	STA <Test_UnOp_OperandTargetAddrHi; Modify the pointers
	LDA <Test_UnOp_ValueAtAddressForTest; Load the initial value for the test.
	STY <Copy_Y
	LDY #0
	STA [Test_UnOp_ExpectedResultAddrLo],Y
	LDY <Copy_Y
	JSR TEST_VerifyInstructionIsTwoByte
	RTS

TEST_UnOp_SetupAddrMode_ZPY:
	;;; Set up the test for Zero Page addressed ;;;
	STY <Copy_Y
	LDA <Test_UnOp_OperandTargetAddrLo
	; Only ever test from $50 to $5F
	AND #$0F
	ORA #$50
	STA <Test_UnOp_ExpectedResultAddrLo; Modify the pointers
	SEC
	SBC <Copy_Y	
	STA UnOpTest_Operand
	STA <Test_UnOp_OperandTargetAddrLo ; Modify the pointers
	LDA #0
	STA <Test_UnOp_ExpectedResultAddrHi; Modify the pointers
	STA <Test_UnOp_OperandTargetAddrHi; Modify the pointers
	LDA <Test_UnOp_ValueAtAddressForTest; Load the initial value for the test.
	LDY #0
	STA [Test_UnOp_ExpectedResultAddrLo],Y
	LDY <Copy_Y
	JSR TEST_VerifyInstructionIsTwoByte
	RTS
;;;;;;;
TEST_UnOp_SetupAddrMode_Abs:
	;;; Set up the test for Absolute addressed ;;;
	LDA <Test_UnOp_OperandTargetAddrLo
	STA UnOpTest_Operand
	LDA <Test_UnOp_OperandTargetAddrHi
	STA UnOpTest_Operand2
	LDA <Test_UnOp_ValueAtAddressForTest
	STY <Copy_Y
	LDY #0
	STA [Test_UnOp_OperandTargetAddrLo],Y
	STA [Test_UnOp_ExpectedResultAddrLo],Y
	LDY <Copy_Y
	JSR TEST_VerifyInstructionIsThreeByte
	RTS
;;;;;;;
TEST_UnOp_SetupAddrMode_AbsX:
;;; Set up the test for Absolute, X addressed ;;;
	STX <Copy_X
	LDA <Test_UnOp_OperandTargetAddrHi
	STA UnOpTest_Operand2
	LDA <Test_UnOp_OperandTargetAddrLo
	SEC
	SBC <Copy_X	
	STA UnOpTest_Operand
	BCS TEST_UnOp_AbsX_DontDecHigh
	DEC UnOpTest_Operand2
TEST_UnOp_AbsX_DontDecHigh	
	LDA <Test_UnOp_ValueAtAddressForTest
	STY <Copy_Y
	LDY #0
	STA [Test_UnOp_OperandTargetAddrLo],Y
	STA [Test_UnOp_ExpectedResultAddrLo],Y
	LDY <Copy_Y
	JSR TEST_VerifyInstructionIsThreeByte
	RTS
TEST_UnOp_SetupAddrMode_AbsY:
	STY <Copy_Y
	LDA <Test_UnOp_OperandTargetAddrHi
	STA UnOpTest_Operand2
	LDA <Test_UnOp_OperandTargetAddrLo
	SEC
	SBC <Copy_Y	
	STA UnOpTest_Operand
	BCS TEST_UnOp_AbsY_DontDecHigh
	DEC UnOpTest_Operand2
TEST_UnOp_AbsY_DontDecHigh	
	LDA <Test_UnOp_ValueAtAddressForTest
	LDY #0
	STA [Test_UnOp_OperandTargetAddrLo],Y
	STA [Test_UnOp_ExpectedResultAddrLo],Y
	LDY <Copy_Y
	JSR TEST_VerifyInstructionIsThreeByte
	RTS
;;;;;;;

TEST_PrepAXYForTest:
	LDX <Test_UnOp_X
	LDY <Test_UnOp_Y
	LDA <Test_UnOp_A
	RTS
;;;;;;;

TEST_UnOpRunTest:
	JSR TEST_PrepAXYForTest	; Set up X and Y for the indexing offsets.
	LDA <$FF ; the opcode
	JSR TEST_UnOp_SetupByAddressingMode ; Set up the operands around $580
	JSR TEST_PrepAXYForTest	; Set up A, X, and Y for the initial values of the test.
	STA <Copy_A
	STX <Copy_X
	JSR $0580	; Run the test!
	RTS
;;;;;;;

Test_UnOpEvaluateResults:
	LDY #0
	LDA [Test_UnOp_ExpectedResultAddrLo],Y
	CMP <Test_UnOp_ValueAtAddressResult
	BNE FAIL_UnOpTest ; Error code 1: The result at the expected address was incorrect
	INC <ErrorCode
Test_UnOpEvaluateResults_StartA:
	LDA <Copy_A
	CMP <Test_UnOp_CMP
	BNE FAIL_UnOpTest ; Error code 2: The result of the A register was incorrect
	INC <ErrorCode
	LDX <Copy_X
	CPX <Test_UnOp_CPX
	BNE FAIL_UnOpTest ; Error code 3: The result of the X register was incorrect
	INC <ErrorCode
	LDY <Copy_Y
	CPY <Test_UnOp_CPY
	BNE FAIL_UnOpTest ; Error code 4: The result of the Y register was incorrect
	INC <ErrorCode
	LDA <Copy_Flags
	CMP <Test_UnOp_CM_Flags
	BNE FAIL_UnOpTest ; Error code 5: The result of the flags were incorrect
	RTS ; Pass!
FAIL_UnOpTest:
	PLA	; Pull of the Return Address
	PLA	;
	PLA
	PLA
	JMP TEST_Fail ; and fail the test.
	
Test_UnOpEvaluateResultsIncludingStackPointer:
	LDY #0
	LDA [Test_UnOp_ExpectedResultAddrLo],Y
	CMP <Test_UnOp_ValueAtAddressResult
	BNE FAIL_UnOpTest ; Error code 1: The result at the expected address was incorrect
	INC <ErrorCode
	LDA <Copy_A
	CMP <Test_UnOp_CMP
	BNE FAIL_UnOpTest ; Error code 2: The result of the A register was incorrect
	INC <ErrorCode
	LDX <Copy_X
	CPX <Test_UnOp_CPX
	BNE FAIL_UnOpTest ; Error code 3: The result of the X register was incorrect
	INC <ErrorCode
	LDY <Copy_Y
	CPY <Test_UnOp_CPY
	BNE FAIL_UnOpTest ; Error code 4: The result of the Y register was incorrect
	INC <ErrorCode
	LDA <Copy_Flags
	CMP <Test_UnOp_CM_Flags
	BNE FAIL_UnOpTest ; Error code 5: The result of the flags were incorrect
	INC <ErrorCode
	LDA <Copy_SP2
	CMP <Test_UnOp_CPS
	BNE FAIL_UnOpTest ; Error code 6: The result of the stack pointer was incorrect
	RTS ; Pass!

TEST_RunTest_AddrInitAXYF:
	;.word TargetAddress
	;.byte Initial, A, X, Y, Flags
	;.word ResultAddress
	;.byte result, r_A, r_X, r_Y, r_Flags
	STA <$FF
	JSR CopyReturnAddressToByte0
	LDY #0
	LDX #0
TEST_AddrInitAXYF_PreLoop:
	LDA [$0000],Y
	STA <Test_UnOp_OperandTargetAddrLo,X
	INY
	INX
	CPX #7 ; Set up $20 through $26
	BNE TEST_AddrInitAXYF_PreLoop
	LDX #0
TEST_AddrInitAXYF_PreLoop2:
	LDA [$0000],Y
	STA <Test_UnOp_ExpectedResultAddrLo,X
	INY
	INX
	CPX #7 ; Set up $28 through $2E
	BNE TEST_AddrInitAXYF_PreLoop2
	; With the variables all set up, let's prep the test:
	JSR FixRTS
	JSR TEST_UnOpRunTest
	; Evaluating the test.
	LDA <initialSubTest
	STA <ErrorCode	
	JSR Test_UnOpEvaluateResults
	; If you made it this far, we passed this test!
	; (not necessarily the entire suite, but this specific test, at least)
	LDA UnOpTest_Opcode ; reset this value before the next test, assuming another one follows
	RTS
;;;;;;;

TEST_UnOp_DMANoEffect:
	; Runs the opcode in A twice with the same inputs: once with no DMA, once with a DMC DMA requested on the cycle
	; before the write (the JSR hook at $0580 and <Test_UnOp_CycleDelayPostDMA>, as in the 2A03 version of these
	; subtests). The second run must give the first run's value at the target address, A, X, Y, flags and stack pointer.
	; Error codes 7 (value), 8 (A), 9 (X), A (Y), B (flags), C (stack pointer).
	;.word TargetAddress   (the instruction must not cross a page with these inputs: the result is read back from here)
	;.byte Initial, A, X, Y, Flags, StackPointer
	STA <$FF
	JSR CopyReturnAddressToByte0
	LDY #0
	LDX #0
TEST_UnOp_DNE_PreLoop:
	LDA [$0000],Y
	STA <Test_UnOp_OperandTargetAddrLo,X
	INY
	INX
	CPX #8 ; Set up $20 through $27
	BNE TEST_UnOp_DNE_PreLoop
	JSR FixRTS
	LDA <Test_UnOp_OperandTargetAddrLo
	STA <Test_UnOp_ExpectedResultAddrLo
	LDA <Test_UnOp_OperandTargetAddrHi
	STA <Test_UnOp_ExpectedResultAddrHi
	LDA #0
	STA $4015                 ; DMC off: the first run has no DMA
	LDY #0
	LDA <Test_UnOp_ValueAtAddressForTest
	STA [Test_UnOp_ExpectedResultAddrLo],Y ; the initial value, written here as well so that both runs start from it
	JSR TEST_UnOpRunTest
	LDY #0                    ; the first run's results are the second run's expected results
	LDA [Test_UnOp_ExpectedResultAddrLo],Y
	STA <Test_UnOp_ValueAtAddressResult
	LDA <Copy_A
	STA <Test_UnOp_CMP
	LDA <Copy_X
	STA <Test_UnOp_CPX
	LDA <Copy_Y
	STA <Test_UnOp_CPY
	LDA <Copy_Flags
	STA <Test_UnOp_CM_Flags
	LDA <Copy_SP2
	STA <Test_UnOp_CPS
	LDA #$20                  ; JSR DMASync_50MinusACyclesRemaining at the start of the RAM function
	STA $0580
	LDA #Low(DMASync_50MinusACyclesRemaining)
	STA $0581
	LDA #High(DMASync_50MinusACyclesRemaining)
	STA $0582
	LDY #0
	LDA <Test_UnOp_ValueAtAddressForTest
	STA [Test_UnOp_ExpectedResultAddrLo],Y ; if the second run's write went anywhere else, this is what is found
	LDA UnOpTest_Opcode
	STA <$FF                  ; the runner takes the opcode from <$FF>, which the first run overwrote (it is also Copy_A)
	JSR TEST_UnOpRunTest
	LDA #$EA                  ; take the hook out again
	STA $0580
	STA $0581
	STA $0582
	LDA #0
	STA $4015
	LDA #7
	STA <ErrorCode
	JSR Test_UnOpEvaluateResultsIncludingStackPointer
	LDA UnOpTest_Opcode
	RTS
;;;;;;;

TEST_RunTest_AddrInitAXYFS:
	;.word TargetAddress
	;.byte Initial, A, X, Y, Flags, StackPointer
	;.word ResultAddress
	;.byte result, r_A, r_X, r_Y, r_Flags, r_StackPointer
	STA <$FF
	JSR CopyReturnAddressToByte0
	LDY #0
	LDX #0
TEST_AddrInitAXYFS_PreLoop:
	LDA [$0000],Y
	STA <Test_UnOp_OperandTargetAddrLo,X
	INY
	INX
	CPX #16 ; Set up $28 through $2F
	BNE TEST_AddrInitAXYFS_PreLoop
	; With the variables all set up, let's prep the test:
	JSR FixRTS
	JSR TEST_UnOpRunTest
	JSR AXYFS_IgnoreStackPointer
	; Evaluating the test.
	LDA <initialSubTest
	STA <ErrorCode	
	JSR Test_UnOpEvaluateResultsIncludingStackPointer
	; If you made it this far, we passed this test!
	; (not necessarily the entire suite, but this specific test, at least)
	LDA UnOpTest_Opcode ; reset this value before the next test, assuming another one follows
	RTS
;;;;;;;

	
TEST_RunTest_ImmOperandAXYF:
	STA <$FF
	JSR CopyReturnAddressToByte0
	LDY #0
	LDX #0
TEST_ImmOperandAXYF_PreLoop:
	LDA [$0000],Y
	STA <Test_UnOp_ValueAtAddressForTest,X
	INY
	INX
	CPX #5 ; Set up $22 through $26
	BNE TEST_ImmOperandAXYF_PreLoop
	LDX #0
TEST_ImmOperandAXYF_PreLoop2:
	LDA [$0000],Y
	STA <Test_UnOp_CMP,X
	INY
	INX
	CPX #4 ; Set up $22 through $26
	BNE TEST_ImmOperandAXYF_PreLoop2
	JSR FixRTS
	JSR TEST_UnOpRunTest
	LDA #2
	STA <ErrorCode	
	JSR Test_UnOpEvaluateResults_StartA
	; If you made it this far, we passed this test!
	; (not necessarily the entire suite, but this specific test, at least)
	LDA UnOpTest_Opcode ; reset this value before the next test, assuming another one follows
	RTS
;;;;;;;

;Test_UnOp_OperandTargetAddrLo = $20
;Test_UnOp_OperandTargetAddrHi = $21
;Test_UnOp_ValueAtAddressForTest = $22
;Test_UnOp_A = $23
;Test_UnOp_X = $24
;Test_UnOp_Y = $25
;Test_UnOp_FlagsInit = $26
;Test_UnOp_SP = $27
;Test_UnOp_ExpectedResultAddrLo = $28
;Test_UnOp_ExpectedResultAddrHi = $29
;Test_UnOp_ValueAtAddressResult = $2A
;Test_UnOp_CMP = $2B
;Test_UnOp_CPX = $2C
;Test_UnOp_CPY = $2D
;Test_UnOp_CM_Flags = $2E
;Test_UnOp_CPS = $2F

;Test_UnOp_IndirectPointerLo = $30
;Test_UnOp_IndirectPointerHi = $31

TEST_SLO_03:
	LDA #$03
	BNE TEST_SLO
TEST_SLO_07:
	LDA #$07
	BNE TEST_SLO
TEST_SLO_0F:
	LDA #$0F
	BNE TEST_SLO
TEST_SLO_13:
	LDA #$13
	BNE TEST_SLO
TEST_SLO_17:
	LDA #$17
	BNE TEST_SLO
TEST_SLO_1B:
	LDA #$1B
	BNE TEST_SLO
TEST_SLO_1F:
	LDA #$1F
TEST_SLO:
	JSR TEST_UnOp_Setup; Set the opcode
	
	; A lot of these unofficial instruction tests will tell you to "see TEST_SLO" for an explanation. Here it is!
	
	; First of all, the test happens in RAM around address $580.
	; The instruction we are testing for begins at address $593.
	; If your emulator has some debug tools, (Or if it doesn't, your IDE probably does...) consider setting a breakpoint when the program counter is at address $593.
	;	
	; The ASM code in this section might look a little confusing...
	; These JSR instructions lead to subroutines that modify the return address
	; so the .word and .byte parts don't get executed.
	; The format of these tests look like this:	
	;
	; JSR TEST_RunTest_AddrInitAXYF
	; iAddress
	; iValue 
	; iA,   iX,   iY,   iflags
	; rAddress
	; rValue 
	; rA,   rX,   rY,   rflags
	;
	; The address at "iAddress" will be assigned the value of "iValue". 
	; The A register will be assigned the value of iA, the X register will be assigned the value of iX, and so on.
	; Then the test runs, which is pretty much just running the instruction in question. In this case, it's some form of SLO.
	; Then, the value of rAddress is compared with rValue. (If it doesn't match, return error code 1)
	; Then, the value of the A register is compared with rA. (If it doesn't match, return error code 2)
	; Then, the value of the X register is compared with rX. (If it doesn't match, return error code 3)
	; Then, the value of the Y register is compared with rY. (If it doesn't match, return error code 4)
	; Then, the value of the status flags are compared with rflags. (If they don't match, return error code 5)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0500                                     ; Initialize address $500 with...
	.byte $40                                       ; a value of $40.
	.byte $01, $64, $45, (flag_i | flag_c | flag_z) ; A=$01, X=$64, Y=$45, Flags = I|C|Z
	.word $0500                                     ; Then, after the test runs, check address $500...
	.byte $80                                       ; for a value of $80.
	.byte $81, $64, $45, (flag_i | flag_n)          ; Check if A=$81, X=$64, Y=$45, and flags = I|N
	; SLO ;
	; Let's walk through this one for the sake of documentation.
	; $0500 = $40, A = $01
	; SLO will shift the value at $0500 to the left.
	; $40 << 1 = $80, so that's the new value at $0500
	; then, bitwise OR the A register with the result of that previous step.
	; $01 | $80 = $81.
	; So the result is, $0500 = $80, and A = $81.
	; The Negative, Carry, and Zero are the only flags modified, and they behave like ORA in this instance.
	; So in this case, the negative flag is set, carry is cleared, and zero is cleared.	
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $057F                                              ; Initialize address $57F with...
	.byte $FF                                                ; a value of $FF.
	.byte $00, $21, $9E, (flag_i | flag_v)                   ; A=$00, X=$21, Y=$9E, Flags = I|V
	.word $057F                                              ; Then, after the test runs, check address $57F...
	.byte $FE                                                ; for a value of $FE.
	.byte $FE, $21, $9E, (flag_i | flag_n | flag_c | flag_v) ; Check if A=$FE, X=$21, Y=$9E, and flags = I|N|C|V
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $05FF                            ; Initialize address $5FF with...
	.byte $00                              ; a value of $00.
	.byte $00, $FF, $FF, (flag_i | flag_c) ; A=$00, X=$FF, Y=$FF, Flags = I|C
	.word $05FF                            ; Then, after the test runs, check address $5FF...
	.byte $00                              ; for a value of $00.
	.byte $00, $FF, $FF, (flag_i | flag_z) ; Check if A=$00, X=$FF, Y=$FF, and flags = I|Z
	; This one really doesn't have any wild edge cases or anything.
	; it's probably a safe bet to assume if your emulator made it this far, then it's good.	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_RLA_23:
	LDA #$23
	BNE TEST_RLA
TEST_RLA_27:
	LDA #$27
	BNE TEST_RLA
TEST_RLA_2F:
	LDA #$2F
	BNE TEST_RLA
TEST_RLA_33:
	LDA #$33
	BNE TEST_RLA
TEST_RLA_37:
	LDA #$37
	BNE TEST_RLA
TEST_RLA_3B:
	LDA #$3B
	BNE TEST_RLA
TEST_RLA_3F:
	LDA #$3F
TEST_RLA:
	JSR TEST_UnOp_Setup; Set the opcode
	
	; see TEST_SLO for an explanation of the format here.
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0500
	.byte $44
	.byte $C1, $64, $45, (flag_i | flag_c | flag_z)
	.word $0500
	.byte $89
	.byte $81, $64, $45, (flag_i | flag_n)
	; RLA ;
	; ROL, then AND ;

	JSR TEST_RunTest_AddrInitAXYF
	.word $0544
	.byte $0F
	.byte $33, $7B, $FE, (flag_i | flag_z | flag_v)
	.word $0544
	.byte $1E
	.byte $12, $7B, $FE, (flag_i | flag_v)

	JSR TEST_RunTest_AddrInitAXYF
	.word $05BF
	.byte $80
	.byte $A5, $E1, $00, (flag_i | flag_z | flag_n)
	.word $05BF
	.byte $00
	.byte $00, $E1, $00, (flag_i | flag_z | flag_c)

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_SRE_43:
	LDA #$43
	BNE TEST_SRE
TEST_SRE_47:
	LDA #$47
	BNE TEST_SRE
TEST_SRE_4F:
	LDA #$4F
	BNE TEST_SRE
TEST_SRE_53:
	LDA #$53
	BNE TEST_SRE
TEST_SRE_57:
	LDA #$57
	BNE TEST_SRE
TEST_SRE_5B:
	LDA #$5B
	BNE TEST_SRE
TEST_SRE_5F:
	LDA #$5F
TEST_SRE:
	JSR TEST_UnOp_Setup; Set the opcode
	
	; see TEST_SLO for an explanation of the format here.
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0500
	.byte $F0
	.byte $5A, $64, $45, (flag_i | flag_c | flag_z)
	.word $0500
	.byte $78
	.byte $22, $64, $45, (flag_i)
	; SRE ;
	; LSR, then EOR ;

	JSR TEST_RunTest_AddrInitAXYF
	.word $053A
	.byte $48
	.byte $24, $8C, $8D, (flag_i | flag_v)
	.word $053A
	.byte $24
	.byte $00, $8C, $8D, (flag_i | flag_v | flag_z)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $05B1
	.byte $01
	.byte $00, $00, $00, (flag_i)
	.word $05B1
	.byte $00
	.byte $00, $00, $00, (flag_i | flag_c | flag_z)

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_RRA_63:
	LDA #$63
	BNE TEST_RRA
TEST_RRA_67:
	LDA #$67
	BNE TEST_RRA
TEST_RRA_6F:
	LDA #$6F
	BNE TEST_RRA
TEST_RRA_73:
	LDA #$73
	BNE TEST_RRA
TEST_RRA_77:
	LDA #$77
	BNE TEST_RRA
TEST_RRA_7B:
	LDA #$7B
	BNE TEST_RRA
TEST_RRA_7F:
	LDA #$7F
TEST_RRA:
	JSR TEST_UnOp_Setup; Set the opcode
	
	; see TEST_SLO for an explanation of the format here.
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0500
	.byte $D0
	.byte $07, $64, $45, (flag_i | flag_c | flag_z)
	.word $0500
	.byte $E8
	.byte $EF, $64, $45, (flag_i | flag_n)
	; RRA ;
	; ROR, then ADC ;
	; Notably, the ROR behavior updates the carry flag before the ADC.
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0566
	.byte $11
	.byte $F7, $12, $34, (flag_i | flag_z | flag_v)
	.word $0566
	.byte $08
	.byte $00, $12, $34, (flag_i | flag_z | flag_c)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $05E1
	.byte $20
	.byte $90, $7B, $F2, (flag_i | flag_z | flag_c)
	.word $05E1
	.byte $90
	.byte $20, $7B, $F2, (flag_i | flag_v | flag_c)
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_SAX_83:
	LDA #$83
	BNE TEST_SAX
TEST_SAX_87:
	LDA #$87
	BNE TEST_SAX
TEST_SAX_8F:
	LDA #$8F
	BNE TEST_SAX
TEST_SAX_97:
	LDA #$97
TEST_SAX:
	JSR TEST_UnOp_Setup; Set the opcode
	
	; see TEST_SLO for an explanation of the format here.
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0500
	.byte $5A
	.byte $F3, $3F, $45, (flag_i | flag_c | flag_z | flag_v)
	.word $0500
	.byte $33
	.byte $F3, $3F, $45, (flag_i | flag_c | flag_z | flag_v)
	; SAX ;
	; Store A & X;
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $05D3
	.byte $21
	.byte $5A, $A5, $45, (flag_i)
	.word $05D3
	.byte $00
	.byte $5A, $A5, $45, (flag_i)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $05EC
	.byte $21
	.byte $90, $E0, $45, (flag_i | flag_c)
	.word $05EC
	.byte $80
	.byte $90, $E0, $45, (flag_i | flag_c)

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_LAX_A3:
	LDA #$A3
	BNE TEST_LAX
TEST_LAX_A7:
	LDA #$A7
	BNE TEST_LAX
TEST_LAX_AF:
	LDA #$AF
	BNE TEST_LAX
TEST_LAX_B3:
	LDA #$B3
	BNE TEST_LAX
TEST_LAX_B7:
	LDA #$B7
	BNE TEST_LAX
TEST_LAX_BF:
	LDA #$BF
TEST_LAX:
	JSR TEST_UnOp_Setup; Set the opcode
	
	; see TEST_SLO for an explanation of the format here.
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0500
	.byte $00
	.byte $07, $64, $45, (flag_i | flag_c | flag_v)
	.word $0500
	.byte $00
	.byte $00, $00, $45, (flag_i | flag_c | flag_z | flag_v)
	; LAX ;
	; Load A and X ;

	JSR TEST_RunTest_AddrInitAXYF
	.word $05B3
	.byte $9F
	.byte $00, $00, $88, (flag_i | flag_z)
	.word $05B3
	.byte $9F
	.byte $9F, $9F, $88, (flag_i | flag_n)

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_DCP_C3:
	LDA #$C3
	BNE TEST_DCP
TEST_DCP_C7:
	LDA #$C7
	BNE TEST_DCP
TEST_DCP_CF:
	LDA #$CF
	BNE TEST_DCP
TEST_DCP_D3:
	LDA #$D3
	BNE TEST_DCP
TEST_DCP_D7:
	LDA #$D7
	BNE TEST_DCP
TEST_DCP_DB:
	LDA #$DB
	BNE TEST_DCP
TEST_DCP_DF:
	LDA #$DF
TEST_DCP:
	JSR TEST_UnOp_Setup; Set the opcode
	
	; see TEST_SLO for an explanation of the format here.
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0500
	.byte $F5
	.byte $F4, $64, $45, (flag_i)
	.word $0500
	.byte $F4
	.byte $F4, $64, $45, (flag_i | flag_c | flag_z)
	; DCP ;
	; DEC, then  CMP ;
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $05F0
	.byte $00
	.byte $F2, $00, $11, (flag_i)
	.word $05F0
	.byte $FF
	.byte $F2, $00, $11, (flag_i | flag_n)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0522
	.byte $80
	.byte $80, $8F, $E3, (flag_i)
	.word $0522
	.byte $7F
	.byte $80, $8F, $E3, (flag_i | flag_c)
	

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_ISC_E3:
	LDA #$E3
	BNE TEST_ISC
TEST_ISC_E7:
	LDA #$E7
	BNE TEST_ISC
TEST_ISC_EF:
	LDA #$EF
	BNE TEST_ISC
TEST_ISC_F3:
	LDA #$F3
	BNE TEST_ISC
TEST_ISC_F7:
	LDA #$F7
	BNE TEST_ISC
TEST_ISC_FB:
	LDA #$FB
	BNE TEST_ISC
TEST_ISC_FF:
	LDA #$FF
TEST_ISC:
	JSR TEST_UnOp_Setup; Set the opcode
	
	; see TEST_SLO for an explanation of the format here.
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0500
	.byte $3F
	.byte $75, $64, $45, (flag_i)
	.word $0500
	.byte $40
	.byte $34, $64, $45, (flag_i | flag_c)
	; ISC ;
	; INC, then SBC ;
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $05BB
	.byte $96
	.byte $98, $15, $8F, (flag_i)
	.word $05BB
	.byte $97
	.byte $00, $15, $8F, (flag_i | flag_z | flag_c)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $05BB
	.byte $7F
	.byte $05, $15, $8F, (flag_i)
	.word $05BB
	.byte $80
	.byte $84, $15, $8F, (flag_i | flag_v | flag_n)

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;


TEST_SHA_93:
	; Okay, this one needs an explanation.
	; Per my research, it would appear these instructions behave differently with different manufacturers.
	; The big difference here is the "corruption" of the high byte when the Y register indexes beyond a page boundary.
	; With behavior 1, the high byte of the address bus is bitwise ANDed with A AND X.
	; With behavior 2, the high byte of the address bus is bitwise ANDed with X. (The A register doesn't have any affect on this high byte corruption with behavior 2.)
	; With behavior 3, the high byte of the address bus is bitwise ANDed with (A AND MAGIC)
	; With behavior 4, the high byte of the address bus is bitwise ANDed with (A OR X)

	; Both behaviors can have a "magic number", though it is much more common with behavior 2.
	LDA #PostDMACyclesUntilTestInstruction+3
	STA <Test_UnOp_CycleDelayPostDMA	
	; Since we need to run this instruction to determine the behavior *before* running a series of tests, let's first confirm this instruction's length in bytes.
	; This is SHA (Indirect),Y, which is 2 bytes long.
	LDX #0
	.byte $93, $E8
	CPX #0
	BEQ  TEST_SHA_93_CorrectLength
	LDA #2	; error code 0.
	RTS
;;;;;;;
	
TEST_SHA_93_CorrectLength:
	; Determine if this instruction is using behavior 1, 2, 3, or 4. (or not implemented)
	JSR WriteFFToLowestPageBytes
	LDA #$F0
	STA <Test_UnOp_IndirectPointerLo
	LDA #$1E
	STA <Test_UnOp_IndirectPointerHi
	LDA #$55
	LDX #$AA
	LDY #$10
	.byte $93, Test_UnOp_IndirectPointerLo ; SHA (Test_UnOp_IndirectPointerLo), Y ; (Test_UnOp_IndirectPointerLo) = $1EF0
	; Behavior 1: Hi = ($1E+1) & $55 & $AA = 0	    :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 2: Hi = ($1E+1) & $AA = 0A	        :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 3: Hi = ($1E+1) & ($55 & MAGIC) = ??	:: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 4: Hi = ($1E+1) & ($55 | $AA) = 1F   :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; copy to $50 for debugging.
	JSR CopyLowestPageBytesTo60

	LDA $0A00
	CMP #$FF
	BNE TEST_SHA_Behavior2_93_JMP ; if address $0A00 was updated, this is behavior 2.
	LDA <$00
	CMP #$FF
	BNE TEST_SHA_Behavior1_93_JMP ; if address $0000 was updated, this is behavior 1.
	LDA $1F00
	CMP #$15
	BEQ TEST_SHA_Behavior4_93_JMP
	JMP TEST_SHA_Behavior3_93 ; If neither known behavior occurred, we need to do some annoying extra checks.
;;;;;;;
TEST_SHA_Behavior4_93_JMP
	JMP TEST_SHA_Behavior4_93	
TEST_SHA_Behavior2_93_JMP:
	JMP TEST_SHA_Behavior2_93
TEST_SHA_Behavior1_93_JMP:
	JMP TEST_SHA_Behavior1_93
	
TEST_SHA_9F:
	; See TEST_SHA_93 for an explanation.
	LDA #PostDMACyclesUntilTestInstruction+4
	STA <Test_UnOp_CycleDelayPostDMA
	; Since we need to run this instruction to determine the behavior *before* running a series of tests, let's first confirm this instruction's length in bytes.
	; This is SHA Absolute, which is 3 bytes long.
	LDX #0
	.byte $9F, $E8, $E8
	CPX #0
	BEQ  TEST_SHA_9F_CorrectLength
	LDA #2	; error code 0.
	RTS
;;;;;;;
	
TEST_SHA_9F_CorrectLength:
	
	; Determine if this instruction is using behavior 1, 2, 3, or 4. (or not implemented)
	JSR WriteFFToLowestPageBytes
	LDA #$55
	LDX #$AA
	LDY #$10
	.byte $9F, $F0, $1E	; SHA $1EF0, Y
	; Behavior 1: Hi = ($1E+1) & $55 & $AA = 0	    :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 2: Hi = ($1E+1) & $AA = 0A	        :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 3: Hi = ($1E+1) & ($55 & MAGIC) = ??	:: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 4: Hi = ($1E+1) & ($55 | $AA) = 1F   :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	;		"MAGIC" has been seen to be 00, F5, F9, FA, and FF. Probably other values too.

	
	JSR CopyLowestPageBytesTo60
	LDA $0A00
	CMP #$FF
	BNE TEST_SHA_Behavior2_9F_JMP ; if address $0A00 was updated, this is behavior 2.
	LDA <$00
	CMP #$FF
	BNE TEST_SHA_Behavior1_9F_JMP ; if address $0000 was updated, this is behavior 1.
	LDA $1F00
	CMP #$15
	BEQ TEST_SHA_Behavior4_9F_JMP
	JMP TEST_SHA_Behavior3_9F ; If neither known behavior occurred, we need to do some annoying extra checks.
;;;;;;;
TEST_SHA_Behavior4_9F_JMP
	JMP TEST_SHA_Behavior4_9F
TEST_SHA_Behavior2_9F_JMP:
	JMP TEST_SHA_Behavior2_9F
TEST_SHA_Behavior1_9F_JMP:
	JMP TEST_SHA_Behavior1_9F

TEST_SHA_Behavior1_93:
	LDA #$93
	PHA
	LDA <RunningAllTests
	BNE TEST_SHA_Behavior1_SkipPrints1
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22B0
	.byte " SHA Behavior 1", $FF
	JSR PrintTextCentered
	.word $2330
	.byte "SHA magic = $", $FF
	LDA #$F0
	STA <$60
	LDA #$FE
	STA <$61
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $93, $60 ; SHA ($0060), Y
	LDA <$50
	JSR PrintByte
	
	JSR ResetScrollAndWaitForVBlank
TEST_SHA_Behavior1_SkipPrints1:
	JMP TEST_SHA_Behavior1
TEST_SHA_Behavior1_9F:
	LDA #$9F
	PHA
	LDA <RunningAllTests
	BNE TEST_SHA_Behavior1_SkipPrints
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22B0
	.byte " SHA Behavior 1", $FF
	JSR PrintTextCentered
	.word $2330
	.byte "SHA magic = $", $FF
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $9F, $F0, $FE ; SHA $FEF0, Y
	LDA <$50
	JSR PrintByte
	
	JSR ResetScrollAndWaitForVBlank
TEST_SHA_Behavior1_SkipPrints:
TEST_SHA_Behavior1:

	PLA

	JSR TEST_UnOp_Setup; Set the opcode
	; This test follows the documented behavior of these instructions. Most emulators probably go here.
	; Special thanks to 8BitLord64 for help researching this.
	; Write: A & X & H
	; Hi = Hi & A & X
	JSR TEST_RunTest_AddrInitAXYF
	.word $0525
	.byte $FF
	.byte $FF, $FF, $00, (flag_i)
	.word $0525
	.byte $06
	.byte $FF, $FF, $00, (flag_i)
	; SHA ;
	; This test needs to be VERY carefully made
	; the high byte of the target address can be modified "unexpectedly"
	; let's run some tests where the high byte doesn't change.
	; Store (A & X & H), where "H" is the high byte of the target address + 1.
	JSR TEST_RunTest_AddrInitAXYF
	.word $1D00	; If someone is testing for this instruction, they would surely have RAM mirroring implemented.
	.byte $FF
	.byte $3F, $FF, $00, (flag_i | flag_c | flag_z | flag_v)
	.word $0500
	.byte $1E
	.byte $3F, $FF, $00, (flag_i | flag_c | flag_z | flag_v)
	
	; Now to make the high byte go unstable.
	JSR TEST_RunTest_AddrInitAXYF
	.word $1F10 ; $1E90 will be the operand.
	.byte $FF
	.byte $0D, $FF, $80, (flag_i | flag_c | flag_z | flag_v)
	.word $0510
	.byte $0D
	.byte $0D, $FF, $80, (flag_i | flag_c | flag_z | flag_v)
	; Hi = ($1E+1) & A & X;
	; 	 = $05
	; $510 = A & X & H
	;	   = $0D & $15 & $1F
	;	   = 5
	INC <$55 ; make this non-zero for the test.	
	JSR TEST_RunTest_AddrInitAXYF
	.word $0555 ; $0402 will be the operand.
	.byte $FF
	.byte $F0, $FF, $FF, (flag_i)
	.word $0055
	.byte $00
	.byte $F0, $FF, $FF, (flag_i)
	; Hi = ($1E+1) & A & X;
	; 	 = $00
	; $510 = A & X & H
	;	   = $0D & $15 & $1F
	;	   = 5
	
	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $8F, $FF, $00, (flag_i), $80
;; END OF TEST ;;
	LDA #5	; Pass, "code 1"
	RTS
;;;;;;;
	
TEST_SHA_Behavior2_93:
	LDA #$93
	PHA	
	LDA <RunningAllTests
	BNE TEST_SHA_Behavior2_SkipPrints1
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22B0
	.byte " SHA Behavior 2", $FF
	JSR PrintTextCentered
	.word $2330
	.byte "SHA magic = $", $FF
	LDA #$F0
	STA <$60
	LDA #$FE
	STA <$61
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $93, $60; SHA ($0060), Y
	LDA <$50
	JSR PrintByte
	
	JSR ResetScrollAndWaitForVBlank
TEST_SHA_Behavior2_SkipPrints1:
	JMP TEST_SHA_Behavior2
TEST_SHA_Behavior2_9F:
	LDA #$9F
	PHA	
	LDA <RunningAllTests
	BNE TEST_SHA_Behavior2_SkipPrints
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22B0
	.byte " SHA Behavior 2", $FF
	JSR PrintTextCentered
	.word $2330
	.byte "SHA magic = $", $FF
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $9F, $F0, $FE ; SHA $FEF0, Y
	LDA <$50
	JSR PrintByte
	
	JSR ResetScrollAndWaitForVBlank
TEST_SHA_Behavior2_SkipPrints:
TEST_SHA_Behavior2:
	PLA
	JSR TEST_UnOp_Setup; Set the opcode
	; This test follows the behavior of many consoles I tested, though differs from the documentation.
	; Special thanks to GTAce, Fiskbit, and Lain for helping research this.
	; Write: A & (X | Magic) & H
	; Hi = Hi & X
	
	; We can not make any assumptions on what "magic" is. Therefore, X needs to always be FF, or at least contain the same bits as A.
	JSR TEST_RunTest_AddrInitAXYF
	.word $0525
	.byte $FF
	.byte $FF, $FF, $10, (flag_i)
	.word $0525
	.byte $06
	.byte $FF, $FF, $10, (flag_i)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $1D00
	.byte $FF
	.byte $03, $13, $00, (flag_i)
	.word $0500
	.byte $02
	.byte $03, $13, $00, (flag_i)
	
	; Now to make the high byte go unstable.
	; We need to make sure X equals A here, since we don't know what MAGIC will be.
	JSR TEST_RunTest_AddrInitAXYF
	.word $1F10 ; $1E90 will be the operand.
	.byte $FF
	.byte $0A, $0A, $80, (flag_i | flag_c | flag_z | flag_v)
	.word $0A10
	.byte $0A
	.byte $0A, $0A, $80, (flag_i | flag_c | flag_z | flag_v)
	; the high byte will only be ANDed with X (FF in this case)
	
	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $8F, $FF, $00, (flag_i), $80
	
	;; END OF TEST ;;
	LDA #9	; Pass, "code 2"
	RTS
;;;;;;;

TEST_SHS_9B:
	; See TEST_SHA_93 for more information.
	LDA #PostDMACyclesUntilTestInstruction+4
	STA <Test_UnOp_CycleDelayPostDMA
	; Determine if this instruction is using behavior 1, 2, 3, or 4. (or not implemented)
	; Since we need to run this instruction to determine the behavior *before* running a series of tests, let's first confirm this instruction's length in bytes.
	; This is SHS Absolute, which is 3 bytes long.
	TSX
	STX <Copy_SP
	LDX #0
	.byte $9B, $E8, $E8
	CPX #0
	BEQ  TEST_SHS_9B_CorrectLength
	LDX <Copy_SP
	TXS
	LDA #2	; error code 0.
	RTS
;;;;;;;
	
TEST_SHS_9B_CorrectLength:
	; Whichever choice of behavior your emulator used for SHA, (behavior 1 vs behavior 2) you should use the same choice of behavior for the SHS instruction. (behavior 1 or behavior 2)
	LDX <Copy_SP
	TXS
	JSR WriteFFToLowestPageBytes
	TSX
	STX <Copy_SP
	LDA #$55
	LDX #$AA
	LDY #$10
	.byte $9B, $F0, $1E	; SHS $1EF0, Y
	; Behavior 1: Hi = ($1E+1) & $55 & $AA = 0	    :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 2: Hi = ($1E+1) & $AA = 0A	        :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 3: Hi = ($1E+1) & ($55 & MAGIC) = ??	:: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	; Behavior 4: Hi = ($1E+1) & ($55 | $AA) = 1F   :: write ($1E+1) & $55 & ($AA | MAGIC) = ?? & $1F (we don't know what MAGIC is, but the result must be $1F or less)
	JSR CopyLowestPageBytesTo60
	LDX <Copy_SP
	TXS
	LDA $A00
	CMP #$FF
	BNE TEST_SHS_Behavior2_9B_JMP ; if address $0A00 was updated, this is behavior 2.
	LDA <$00
	CMP #$FF
	BNE TEST_SHS_Behavior1_9B ; if address $0000 was updated, this is behavior 1.
	LDA $1F00
	CMP #$15
	BEQ TEST_SHS_Behavior4_9B_JMP
	JMP TEST_SHS_Behavior3_9B ; If neither known behavior occurred, we need to do some annoying extra checks.
;;;;;;;

TEST_SHS_Behavior4_9B_JMP:
	JMP TEST_SHS_Behavior4_9B
	
TEST_SHS_Behavior2_9B_JMP:
	JMP TEST_SHS_Behavior2_9B
	
TEST_SHS_Behavior1_9B:
	LDA <RunningAllTests
	BNE TEST_SHS_Behavior1_SkipPrints
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22D0
	.byte " SHS Behavior 1", $FF
	JSR PrintTextCentered
	.word $2350
	.byte "SHS magic = $", $FF
	TSX
	STX <Copy_SP
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $9B, $F0, $FE ; SHS $FEF0, Y
	LDX <Copy_SP
	TXS
	LDA <$50
	JSR PrintByte
	JSR ResetScrollAndWaitForVBlank
TEST_SHS_Behavior1_SkipPrints:
	LDA #$9B
	JSR TEST_UnOp_Setup; Set the opcode
	; This test follows the documented behavior of these instructions. Most emulators probably go here.
	; Special thanks to 8BitLord64 for help researching this.
	; Write: A & X & H
	; Hi = Hi & A & X
	JSR TEST_RunTest_AddrInitAXYFS
	.word $0525
	.byte $FF
	.byte $FF, $FF, $00, (flag_i), $FF
	.word $0525
	.byte $06
	.byte $FF, $FF, $00, (flag_i), $FF
	; SHS ;
	; This test needs to be VERY carefully made
	; This test also modifies the stack pointer.
	; the high byte of the target address can be modified "unexpectedly"
	; let's run some tests where the high byte doesn't change.
	; Store (A & X & H), where "H" is the high byte of the target address + 1.
	JSR TEST_RunTest_AddrInitAXYFS
	.word $1D00	; If someone is testing for this instruction, they would surely have RAM mirroring implemented.
	.byte $FF
	.byte $3F, $F5, $00, (flag_i | flag_c | flag_z | flag_v), $56
	.word $0500
	.byte $14
	.byte $3F, $F5, $00, (flag_i | flag_c | flag_z | flag_v), $35
	
	; Now to make the high byte go unstable.
	JSR TEST_RunTest_AddrInitAXYFS
	.word $1F10 ; $1E90 will be the operand.
	.byte $FF
	.byte $0D, $15, $80, (flag_i | flag_c | flag_z | flag_v), $FF
	.word $0510
	.byte $05
	.byte $0D, $15, $80, (flag_i | flag_c | flag_z | flag_v), $05
	; Hi = ($1E+1) & A & X;
	; 	 = $05
	; $510 = A & X & H
	;	   = $0D & $15 & $1F
	;	   = 5
	INC <$55 ; make this non-zero for the test.	
	JSR TEST_RunTest_AddrInitAXYFS
	.word $0555 ; $0402 will be the operand.
	.byte $FF
	.byte $F0, $09, $FF, (flag_i), $77
	.word $0055
	.byte $00
	.byte $F0, $09, $FF, (flag_i), $00
	; Hi = ($1E+1) & A & X;
	; 	 = $00
	; $510 = A & X & H
	;	   = $0D & $15 & $1F
	;	   = 5
	
	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $8F, $FF, $00, (flag_i), $9F
;; END OF TEST ;;
	LDA #5	; Pass "code 1"
	RTS
;;;;;;;

TEST_SHS_Behavior2_9B:
	LDA <RunningAllTests
	BNE TEST_SHS_Behavior2_SkipPrints
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22D0
	.byte " SHS Behavior 2", $FF
	JSR PrintTextCentered
	.word $2350
	.byte "SHS magic = $", $FF
	TSX
	STX <Copy_SP
	LDA #$FF
	LDX #$00
	LDY #$60
	.byte $9B, $F0, $FE ; SHS $FEF0, Y
	LDX <Copy_SP
	TXS
	LDA <$50
	JSR PrintByte
	JSR ResetScrollAndWaitForVBlank
TEST_SHS_Behavior2_SkipPrints:
	LDA #$9B
	JSR TEST_UnOp_Setup; Set the opcode
	JSR TEST_RunTest_AddrInitAXYFS
	.word $0525
	.byte $FF
	.byte $FF, $FF, $10, (flag_i), $FF
	.word $0525
	.byte $06
	.byte $FF, $FF, $10, (flag_i), $FF
	
	JSR TEST_RunTest_AddrInitAXYFS
	.word $1D00
	.byte $FF
	.byte $03, $FF, $00, (flag_i), $FF
	.word $0500
	.byte $02
	.byte $03, $FF, $00, (flag_i), $03
	
	JSR TEST_RunTest_AddrInitAXYFS
	.word $1F10 ; $1E90 will be the operand.
	.byte $FF
	.byte $0A, $0A, $80, (flag_i | flag_c | flag_z | flag_v), $7E
	.word $0A10
	.byte $0A
	.byte $0A, $0A, $80, (flag_i | flag_c | flag_z | flag_v), $0A

	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $8F, $FF, $00, (flag_i), $9F

;; END OF TEST ;;
	LDA #9	; Pass "code 2"
	RTS
;;;;;;;

TEST_SHY_9C:
	LDA #PostDMACyclesUntilTestInstruction+4
	STA <Test_UnOp_CycleDelayPostDMA
	LDA #$9C
	JSR TEST_UnOp_Setup; Set the opcode
	JSR TEST_RunTest_AddrInitAXYF
	.word $15BB
	.byte $7F
	.byte $11, $00, $FF, (flag_i)
	.word $15BB
	.byte $16
	.byte $11, $00, $FF, (flag_i)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $1D00
	.byte $7F
	.byte $33, $00, $0F, (flag_i)
	.word $1D00
	.byte $0E
	.byte $33, $00, $0F, (flag_i)

	; Goes unstable.
	JSR TEST_RunTest_AddrInitAXYF
	.word $1F10
	.byte $7F
	.byte $77, $80, $05, (flag_i)
	.word $510
	.byte $05
	.byte $77, $80, $05, (flag_i)

	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $80, $00, $A5, (flag_i), $80
;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_SHX_9E:
	LDA #PostDMACyclesUntilTestInstruction+4
	STA <Test_UnOp_CycleDelayPostDMA
	LDA #$9E
	JSR TEST_UnOp_Setup; Set the opcode
	JSR TEST_RunTest_AddrInitAXYF
	.word $15BB
	.byte $7F
	.byte $11, $FF, $00, (flag_i)
	.word $15BB
	.byte $16
	.byte $11, $FF, $00, (flag_i)
	
	JSR TEST_RunTest_AddrInitAXYF
	.word $1D00
	.byte $7F
	.byte $33, $0F, $00, (flag_i)
	.word $1D00
	.byte $0E
	.byte $33, $0F, $00, (flag_i)

	; Goes unstable.
	JSR TEST_RunTest_AddrInitAXYF
	.word $1F10
	.byte $7F
	.byte $77, $05, $80, (flag_i)
	.word $510
	.byte $05
	.byte $77, $05, $80, (flag_i)

	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $80, $A5, $00, (flag_i), $80
;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_LAE_BB:
	LDA #$BB
	JSR TEST_UnOp_Setup; Set the opcode
	JSR TEST_RunTest_AddrInitAXYFS
	.word $500
	.byte $5A
	.byte $11, $FF, $00, (flag_i | flag_v), $CA
	.word $500
	.byte $5A
	.byte $4A, $4A, $00, (flag_i | flag_v), $4A

	JSR TEST_RunTest_AddrInitAXYFS
	.word $5E3
	.byte $C3
	.byte $7C, $99, $52, (flag_i), $9A
	.word $5E3
	.byte $C3
	.byte $82, $82, $52, (flag_i | flag_n), $82
	
	JSR TEST_RunTest_AddrInitAXYFS
	.word $5E3
	.byte $04
	.byte $AB, $CD, $EF, (flag_i | flag_c | flag_n), $90
	.word $5E3
	.byte $04
	.byte $00, $00, $EF, (flag_i | flag_c | flag_z), $00 ;
	; NOTE: Yes, the stack pointer will be set to 00;
	;       Yes, the test will then PHA and PHP.
	;       No, this will not corrupt the bottom of the stack, for the stack pointer is initialized to $EF during the reset routine I wrote.
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_ANC_0B:
	LDA #$0B
	BNE TEST_ANC
TEST_ANC_2B:
	LDA #$2B
TEST_ANC:
	; see TEST_SLO for an explanation of how these tests work.
	; Except this one is slightly different, so let me explain.
	; TEST_RunTest_ImmOperandAXYF is similar to TEST_RunTest_AddrInitAXYF,
	; but instead of iAddress, iValue, iA, iX, iY, iFlags, rAddress, rValue, rA, rX, rY, rFlags
	; this function uses operand, iA, iX, iY, iFlags, rA, rX, rY, rFlags.
	; Error code 2 means A didn't match the expected result.
	; Error code 3 means X didn't match the expected result.
	; Error code 4 means Y didn't match the expected result.
	; Error code 5 means the flags didn't match the expected result.
	JSR TEST_UnOp_Setup ; Set the opcode
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $F0
	.byte $5A, $64, $45, (flag_i | flag_z | flag_c)
	.byte $50, $64, $45, (flag_i)
	; ANC ;
	; Bitwise AND with Accumulator then Set Carry if Negative
	; $5A & $F0 = 50	
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $F5
	.byte $81, $00, $01, (flag_i | flag_v)
	.byte $81, $00, $01, (flag_i | flag_c | flag_n | flag_v)
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $5A
	.byte $A5, $FF, $5A, (flag_i | flag_c)
	.byte $00, $FF, $5A, (flag_i | flag_z)	
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;	
	
TEST_ASR_4B:
	LDA #$4B
	JSR TEST_UnOp_Setup ; Set the opcode
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $F0
	.byte $81, $64, $45, (flag_i | flag_z | flag_c)
	.byte $40, $64, $45, (flag_i)
	; ASR ;
	; Bitwise AND with Accumulator then Logical Shift Right Accumulator
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $52
	.byte $43, $00, $01, (flag_i | flag_c | flag_v)
	.byte $21, $00, $01, (flag_i | flag_v)
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $41
	.byte $BF, $55, $AA, (flag_i | flag_z | flag_c)
	.byte $00, $55, $AA, (flag_i | flag_z | flag_c)	
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_ARR_6B:
	LDA #$6B
	JSR TEST_UnOp_Setup ; Set the opcode
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $F2
	.byte $EE, $64, $45, (flag_i | flag_z | flag_v)
	.byte $71, $64, $45, (flag_i | flag_c)
	; ARR ;
	; Bitwise AND with A then Rotate A Right and check bits
	; Negative flag = bit 7
	; Carry flag = bit 6
	; Overflow flag = bit 5 XOR bit 6
	; Zero flag = result is zero
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $01
	.byte $59, $64, $45, (flag_i | flag_z)
	.byte $00, $64, $45, (flag_i | flag_z)
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $4F
	.byte $F3, $64, $45, (flag_i | flag_z | flag_c)
	.byte $A1, $64, $45, (flag_i | flag_v | flag_n)
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_ANE_8B:
	LDA #$8B
	JSR TEST_UnOp_Setup ; Set the opcode
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $00
	.byte $5A, $3B, $45, (flag_i | flag_z | flag_c)
	.byte $00, $3B, $45, (flag_i | flag_z | flag_c)
	; ANE ;
	; A = (((A | Magic) & X) & Immediate)
	; The "Magic" value is not consistent, and so this test cannot rely on any specific value.
	; It is possible to test and see what this value is, but it could be different between instances of running the test.
	; Because of this, the tests used here need to specifically verify behavior only in cases where the magic value does not alter the outcome.
	; Basically, unless Immediate is $00, or A is $FF, the outcome is not guaranteed.
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $CF
	.byte $FF, $9F, $99, (flag_i | flag_z | flag_v)
	.byte $8F, $9F, $99, (flag_i | flag_n | flag_v)
	
	; That's pretty much all we can test with this instruction, so we're good to go!
	; Let's also determine the magic number, and draw that on screen.
	LDA RunningAllTests
	BNE ANE_SkipPrintMagic
	JSR WaitForVBlank
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $2330
	.byte "ANE magic = $", $FF
	LDA #0
	LDX #$FF
	.byte $8B, $FF ; ANE #$FF
	JSR PrintByte
	JSR ResetScroll
ANE_SkipPrintMagic:
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_LXA_AB:
	LDA #$AB
	JSR TEST_UnOp_Setup ; Set the opcode
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $00
	.byte $5A, $3B, $45, (flag_i | flag_z | flag_c)
	.byte $00, $00, $45, (flag_i | flag_z | flag_c)
	; LXA ;
	; A = ((A | Magic) & Immediate), X = A
	; The "Magic" value is not consistent, and so this test cannot rely on any specific value.
	; It is possible to test and see what this value is, but it could be different between tests.
	; Because of this, the tests used here need to specifically verify behavior only in cases where the magic value does not alter the outcome.
	; Basically, unless Immediate is $00, or A is $FF, the outcome is not guaranteed.
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $A5
	.byte $FF, $8F, $99, (flag_i | flag_z | flag_v)
	.byte $A5, $A5, $99, (flag_i | flag_n | flag_v)
	
	; That's pretty much all we can test with this instruction, so we're good to go!
	; Let's also determine the magic number, and draw that on screen.
	LDA RunningAllTests
	BNE LXA_SkipPrintMagic
	JSR WaitForVBlank
	JSR PrintTextCentered
	.word $2350
	.byte "LXA magic = $", $FF
	LDA #0
	.byte $AB, $FF ; LXA #$FF
	JSR PrintByte
	JSR ResetScroll
LXA_SkipPrintMagic:
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;
	
TEST_AXS_CB:
	LDA #$CB
	JSR TEST_UnOp_Setup ; Set the opcode
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $10
	.byte $F0, $B0, $45, (flag_i | flag_z | flag_c)
	.byte $F0, $A0, $45, (flag_i | flag_c | flag_n)
	; AXS ;
	; X = (A&X) - Immediate
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $00
	.byte $5A, $CC, $FF, (flag_i | flag_z | flag_c)
	.byte $5A, $48, $FF, (flag_i | flag_c)
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $E5
	.byte $00, $66, $45, (flag_i | flag_z | flag_c | flag_v)
	.byte $00, $1B, $45, (flag_i | flag_v)
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $45
	.byte $C5, $5F, $00, (flag_i | flag_n)
	.byte $C5, $00, $00, (flag_i | flag_z | flag_c)
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $40
	.byte $10, $50, $00, (flag_i | flag_n)
	.byte $10, $D0, $00, (flag_i | flag_n)
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_SBC_EB:
	LDA #$EB
	JSR TEST_UnOp_Setup ; Set the opcode
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $10
	.byte $F0, $22, $75, (flag_i | flag_z | flag_c | flag_v)
	.byte $E0, $22, $75, (flag_i | flag_c | flag_n)
	; SBC ;
	; It's the same as the official SBC Immediate instruction.
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $EE
	.byte $52, $93, $B2, (flag_i)
	.byte $63, $93, $B2, (flag_i)
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $80
	.byte $05, $C0, $1F, (flag_i | flag_z | flag_c | flag_v | flag_n)
	.byte $85, $C0, $1F, (flag_i| flag_v | flag_n)
	
	JSR TEST_RunTest_ImmOperandAXYF
	.byte $43
	.byte $44, $C0, $1F, (flag_i)
	.byte $00, $C0, $1F, (flag_i| flag_z | flag_c)
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_DMA_Plus_OpenBus:
	;;; Test 1 [DMA + Open Bus]: Check if reading from $4000 returns $40, and not zero. ;;;
	LDA $4000
	CMP #$40
	BNE FAIL_DMA_Plus_OpenBus
	INC <ErrorCode

	;;; Test 2 [DMA + Open Bus]: If the DMA occurs just before the Open Bus read, it will update the data bus to $00 ;;;
	; 2A07 form: a DMA leaves its byte on the data bus, which an opcode fetched from open bus sees when the DMA halts
	; the CPU on that fetch (a data read never can on a 2A07: see TEST_OBProbe_Install). DMASync_50CyclesRemaining
	; returns 50 cycles before the DMA's request point R; the probe's $4000 fetch is put on R.
	LDA #LOW(TEST_DMA_Plus_OpenBus_Ret)
	LDX #HIGH(TEST_DMA_Plus_OpenBus_Ret)
	JSR TEST_OBProbe_Install
	JSR DMASync_50CyclesRemaining
	JSR Clockslide_34                ; 34
	LDA #HIGH(TEST_DMA_Plus_OpenBus_Ret) ; 36
	PHA                              ; 39
	LDA #LOW(TEST_DMA_Plus_OpenBus_Ret) ; 41
	PHA                              ; 44
	PHP                              ; 47
	JMP $4000                        ; opcode fetch at 47, $4000 fetch at 50 = R
TEST_DMA_Plus_OpenBus_Ret:
	LDA <$50
	BEQ FAIL_DMA_Plus_OpenBus        ; the DMA did not change the opcode
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_DMA_Plus_OpenBus:
	JMP TEST_Fail

TEST_DMA_Plus_2007_Prep:
	JSR DisableRendering ; let's disable rendering for this one.
	LDX #$2C
	STX $2006
	LDX #0
	STX $2006
	STX $2007 ; write 0 to VRAM $2800
	INX
	STX $2007 ; write 1 to VRAM $2801
	INX
	STX $2007 ; write 2 to VRAM $2802
	INX
	STX $2007 ; write 3 to VRAM $2803
	INX
	STX $2007 ; write 4 to VRAM $2804
	LDX #$2C
	STX $2006
	LDX #$01
	STX $2006 ; and set 'v' back to $2C00
	LDA $2007 ; read $2007 and prep the buffer.
	RTS
;;;;;;;

TEST_DMA_Plus_2007R:
	; Here's the set up:
	; VRAM will read 0 1 2 3 4
	; The LDA $2007 instruction has 4 read cycles.
	; [Opcode] [Operand1] [Operand2] [Read $2007]
	; if the DMA occurs between [Operand2] and [Read $2007], the ppu 'v' register will be incremented twice due to the DMA's dummy cycles.
	; That placement does not exist on a 2A07: its DMA only halts the CPU on an opcode fetch (NESdev forum
	; t=25939), so it waits for the next instruction and the $2007 read is never repeated. The test checks that.
	JSR TEST_DMA_Plus_2007_Prep	
	JSR DMASync_50CyclesRemaining	; sync DMA
	; We have 50 CPU cycles until the DMA occurs.
	JSR Clockslide_47
	LDA $2007 ; <------- [Opcode] [Operand1] [Operand2] [*DMA*] [Read]
	NOP 
	NOP	
	
	;;; Test 1 [DMA + $2007 Read]: verify PPU buffer behavior ;;;
	CMP #$00
	BEQ TEST_Fail7 ; if the value of A is $00, then your PPU buffer is probably not implemented correctly.
	INC <ErrorCode
	
	;;; Test 2 [DMA + $2007 Read]: Check DMA timing ;;;
	CMP #$01
	BNE TEST_Fail7 ; DOC-BACKED: NESdev "APU DMC": the DMA's extra reads give the PPU extra $2007 reads, and
	; "This problem has been fixed on the 2A07", so the read returns $01. Note: on the 2A07 this read cannot see the
	; DMA at all (it only delays it), so tests 2-3 do not check the DMA's timing.
	INC <ErrorCode
	
	;;; Test 3 [DMA + $2007 Read]: Check the DMA dummy reads occurred the correct number of times ;;;	
	; On a 2A07 there are no extra reads to count, so the old check here (CMP #$01 / BMI after test 2 required
	; A = 1) could never fail. 2A07 form: check that the DMA really happened. Test 2's "no extra $2007 read" also holds
	; when no DMA occurs at all; the DMA fetched the sample's only byte, so $4015 bit 4 (bytes remaining) must be 0.
	LDA $4015
	AND #$10
	BNE TEST_Fail7
	INC <ErrorCode
	;; END OF TEST ;;
	
	JSR ResetScrollAndWaitForVBlank
	JSR EnableRendering_BG	
	LDA #1
	RTS
;;;;;;;

TEST_DMA_Plus_2007W:
	; Here's the set up:
	; VRAM will read 0 1 2 3 4
	; The STA $2007 instruction has 3 read cycles, then a write cycle.
	; [Opcode] [Operand1] [Operand2] [Write $2007]
	; However, DMC DMA's cannot interrupt a write cycle! Therefore, the address bus cannot be $2007 during the DMA, so nothing unusual happens!
	; On a 2A07 the reason is wider: its DMA halts only on an opcode fetch, so no cycle of this instruction
	; (read or write) can be interrupted (t=25939, t=26827). Same conclusion.	
	; This test only has relevant results if the DMA + $2007R rest passes.
	;;; Test 1 [DMA + $2007 Write]: The DMA + $2006 Read test passes. ;;;
	JSR TEST_DMA_Plus_2007R
	LDX #1
	STX <ErrorCode
	CMP #1
	BNE TEST_Fail7
	INC <ErrorCode

	JSR TEST_DMA_Plus_2007_Prep	; the v register is now at 2C01
	JSR DMASync_50CyclesRemaining	; sync DMA
	; We have 50 CPU cycles until the DMA occurs.
	JSR Clockslide_45 ;+45 cycles
	LDA #$5A		  ;+2 cycles
	STA $2007 ; <------- [Opcode] [Operand1] [Operand2] [DMA attempts, but fails. Write] [Opcode (NOP)] [*DMA*]
	NOP 	  ; The DMA occurs inside this NOP, if your emulator is timing it right.
	NOP		  ; And the v register is now at $2C02. It was not incremented extra times in the DMA, so LDA $2007 read the expected value.
	;;; Test 2 [DMA + $2007 Write]: The v register should be at $2C02 ;;;
	JSR DoubleLDA2007
	CMP #$03
	BNE TEST_Fail7
	;; END OF TEST ;;
	
	JSR ResetScrollAndWaitForVBlank
	JSR EnableRendering_BG	
	LDA #1
	RTS
;;;;;;;

TEST_Fail7:
	JSR ResetScrollAndWaitForVBlank
TEST_Fail8:
	JSR EnableRendering_BG	
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

Test_ProgramCounter_Wraparound:
	LDX #0
Test_ProgramCounter_WraparoundLoop1:
	LDA TEST_OpenBus_IRQRoutine,X ; Re-use this BRK routine.
	STA $600, X
	INX
	CPX #8
	BNE Test_ProgramCounter_WraparoundLoop1

	;;; Test 1 [Program Counter Wraparound]: Executing from $FFFF should wrap around to address $0000 ;;;
	LDA #$00
	STA <$00
	LDA #$60
	STA <$01
	JSR $FFFF ; .byte $06, $00 = ASL <$00; $01 = 60, RTS
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_VBlank_Beginning:
	; STATUS: DERIVED [2C07] The 2C02 test reads $2002 twice (LDX, then LDY 4 CPU cycles later) and moves the pair one
	; PPU dot per pass across the dot where the VBlank flag is set. On PAL a frame is 33247.5 CPU cycles, so each extra
	; frame of VblSync_Plus_A moves the reads by half a CPU cycle: 1.6 dots. The pair is sampled at 8 positions, 1.6
	; dots apart. The flag rules are the 2C02's (NESdev PPU frame timing: a read one dot before the flag is set returns
	; it clear and suppresses it for this frame). Pending hardware: the CPU/PPU phase of a real console decides whether
	; a sample falls on that one dot.
	;;; Test 1 [VBlank beginning]: Tests the timing of the $2002 VBlank flag. ;;;
	; Each sample is stored at $50+n as 0000 00XY, X = bit 7 of the LDX read, Y = bit 7 of the LDY read:
	;   02: the LDX read is before the flag is set, the LDY read (12.8 dots later) after it.
	;   00: the LDX read is on the dot before the flag would be set: it reads the flag clear and suppresses it, so the
	;       LDY read sees it clear too. (Both reads before the flag would also give 00; the first sample starts after
	;       that, inside the 02 range, as the 2C02 version's first sample does.)
	;   01: the LDX read is after the flag is set (and clears it).
	; Key: the first sample is 02, the last is 01, the samples never go back (02 ... [00] ... 01), and 00 appears at
	; most once. Whether a sample falls on the suppressing dot depends on the CPU/PPU phase; in the measured phase none does.
	JSR DisableRendering
	LDX #0
TEST_VBlank_Beginning_Loop:
	TXA
	PHA
	JSR VblSync_Plus_A
	JSR ClockslideFromWord
	.word 33217 ; the flag is set between the two reads of the first samples (measured: 02 02 02 02 02 01 01 01)
	LDX $2002
	LDY $2002
	TXA
	ASL A
	LDA #0
	ROL A
	STA <$00
	TYA
	ASL A
	LDA #0
	ROL A
	ASL A
	ORA <$00
	STA <$00
	PLA
	TAX
	LDA <$00
	STA <$50,X
	INX
	CPX #$08
	BNE TEST_VBlank_Beginning_Loop
	; Check the key.
	LDA <$50
	CMP #2
	BNE TEST_VBlank_Beginning_Fail ; the first sample must see the flag set between the two reads.
	LDA <$57
	CMP #1
	BNE TEST_VBlank_Beginning_Fail ; the last sample must see the flag already set.
	LDA #2
	STA <$58 ; previous rank
	LDA #0
	STA <$59 ; number of 00 samples
	LDX #0
TEST_VBlank_Beginning_Check:
	LDY <$50,X
	CPY #3
	BEQ TEST_VBlank_Beginning_Fail ; both reads saw the flag set: not possible
	LDA TEST_VBlank_Beginning_Rank,Y
	CMP <$58
	BEQ TEST_VBlank_Beginning_Same
	BCS TEST_VBlank_Beginning_Fail ; a sample went back (later read, earlier result)
TEST_VBlank_Beginning_Same:
	STA <$58
	CPY #0
	BNE TEST_VBlank_Beginning_Next
	INC <$59
TEST_VBlank_Beginning_Next:
	INX
	CPX #$08
	BNE TEST_VBlank_Beginning_Check
	LDA <$59
	CMP #2
	BCS TEST_VBlank_Beginning_Fail ; the suppressing read is one dot wide: at most one sample can hit it
	;; END OF TEST ;;
	LDA #1
	RTS
TEST_VBlank_Beginning_Fail:
	JMP TEST_Fail
TEST_VBlank_Beginning_Rank: ; by sample value 00, 01, 02: the order in which they can follow each other
	.byte 1, 0, 2
;;;;;;;

TEST_VBlank_End:
	; STATUS: DERIVED [2C07] The 2C02 test reads $2002 once per pass, one PPU dot later each pass, across the dot where
	; the VBlank flag is cleared (dot 1 of the pre-render line). On PAL the pre-render line is 311 and VBlank lasts 70
	; scanlines (7459.375 CPU cycles); the read moves 1.6 dots per pass (one extra 33248-cycle frame of VblSync_Plus_A,
	; half a CPU cycle more than a frame). Pending hardware: the CPU/PPU phase of a real console.
	;;; Test 1 [VBlank end]: Tests the timing of the $2002 VBlank flag at the end of VBlank. ;;;
	; Each sample is stored at $50+n: 1 = the flag was still set, 0 = it was already cleared.
	; Key: the first sample is 1, the last is 0, and the samples change only once.
	JSR DisableRendering
	LDX #0
TEST_VBlank_End_Loop:
	TXA
	JSR VblSync_Plus_A
	JSR ClockslideFromWord
	.word 40677 ; the end of the NEXT frame's VBlank (VblSync_Plus_A's last read of $2002 already cleared this frame's
				; flag): one 33248-cycle frame plus about 7459 cycles of VBlank. Measured: 1 1 1 1 0 0 0 0
	LDA $2002
	ASL A	; Shift VBlank flag into carry
	LDA #0	; clear A
	ROL A	; Rotate carry into bit 0.
	STA <$50,X	; store in $50,X
	INX
	CPX #$08
	BNE TEST_VBlank_End_Loop ; loop until X=8
	LDA <$50
	CMP #1
	BNE TEST_VBlank_End_Fail ; the first sample must still see the flag set
	LDA <$57
	BNE TEST_VBlank_End_Fail ; the last sample must see it cleared
	LDY #0 ; number of changes
	LDX #1
TEST_VBlank_End_Check:
	LDA <$50,X
	CMP <$4F,X
	BEQ TEST_VBlank_End_Same
	INY
TEST_VBlank_End_Same:
	INX
	CPX #$08
	BNE TEST_VBlank_End_Check
	CPY #1
	BNE TEST_VBlank_End_Fail ; the flag is cleared once, at one dot
	;; END OF TEST ;;
	LDA #1
	RTS
TEST_VBlank_End_Fail:
	JMP TEST_Fail
;;;;;;;


TEST_NMI_Timing:
	; STATUS: DERIVED [2C07] The 2C02 test with the read stepped as in [VBlank beginning]: 10 samples, 1.6 dots apart
	; (one extra 33248-cycle frame of VblSync_Plus_A per sample). The NMI handler stores Y; the NMI lands in a chain of
	; INY instructions, so Y tells which INY it interrupted. Pending hardware: the CPU/PPU phase of a real console.
	LDA #$84	; STY <$zp opcode
	STA $700
	LDA #Copy_Y
	STA $701
	LDA #$40	; RTI opcode
	STA $702
	; The NMI routine is now:
	; STY <Copy_Y
	; RTI
	JSR DisableRendering
	LDX #0
	;;; Test 1 [NMI Timing]: Tests the timing of the NMI. ;;;
	; Key: Y never goes up from one sample to the next, it goes down by 1 at a time, every value between the first and
	; the last lasts exactly 4 samples (an INY is 2 CPU cycles, 6.4 dots, 4 steps of 1.6 dots), and at least two values
	; are seen (the NMI falls inside the INY chain, so it comes at the time the VBlank flag is set, within a few cycles).
TEST_NMI_Timing_Loop:
	TXA
	LDY #$80
	STA <Copy_Y
	LDY #1
	JSR VblSync_Plus_A
	JSR ClockslideFromWord
	.word 33139 ; the INY chain below starts 80 cycles later, around the VBlank flag. Measured: 04 04 04 03 03 03 03 02 02 02
	JSR EnableNMI ; This takes 31 cycles.
	JSR Clockslide_49
	INY
	INY
	INY
	INY
	LDY <Copy_Y
	STY <$50,X
	JSR DisableNMI
	INX
	CPX #$0A
	BNE TEST_NMI_Timing_Loop
	; Check the key.
	LDA #0
	STA <$5C ; changes seen
	LDA #1
	STA <$5D ; length of the current run
	LDX #1
TEST_NMI_Timing_Check:
	LDA <$4F,X
	SEC
	SBC <$50,X ; previous - this
	BEQ TEST_NMI_Timing_SameRun
	CMP #1
	BNE TEST_NMI_Timing_Fail ; it went up, or down by more than 1
	LDA <$5C
	BEQ TEST_NMI_Timing_FirstRun ; the first run can be cut short by the start of the sweep
	LDA <$5D
	CMP #4
	BNE TEST_NMI_Timing_Fail ; an inner run has to be exactly 4 samples (2 CPU cycles)
TEST_NMI_Timing_FirstRun:
	INC <$5C
	LDA #1
	STA <$5D
	BNE TEST_NMI_Timing_Next
TEST_NMI_Timing_SameRun:
	INC <$5D
TEST_NMI_Timing_Next:
	INX
	CPX #$0A
	BNE TEST_NMI_Timing_Check
	LDA <$5C
	BEQ TEST_NMI_Timing_Fail ; Y never changed: the NMI did not come inside the INY chain
	;; END OF TEST ;;
	LDA #1
	RTS
TEST_NMI_Timing_Fail:
	JSR DisableNMI
	JMP TEST_Fail
;;;;;;;

TEST_NMI_Suppression:
	; STATUS: DERIVED [2C07] The 2C02 test with the read stepped as in [VBlank beginning]: 10 samples 1.6 dots apart. A
	; read of $2002 close to the dot where the VBlank flag is set suppresses the NMI and/or the flag (NESdev PPU frame
	; timing; the 2C07's NMI logic is the 2C02's, Visual 2C07). Pending hardware: the CPU/PPU phase of a real console.
	;;; Test 1 [NMI Suppression]: Tests the timing of the NMI and VBlank flag when $2002 is read near the start of VBlank. ;;;
	; Each sample is 0000 00YV: Y = the NMI happened, V = the read saw the VBlank flag.
	;   02: read before the flag is set; the NMI happens. (A read much earlier also gives 00, because the NMI then comes
	;       after Y is copied; the first sample starts after that, inside the 02 range, as the 2C02 version's does.)
	;   00: read one dot before the flag is set: flag and NMI suppressed.
	;   01: read as the flag is set: the NMI is suppressed.          03: read after: flag seen, NMI happens.
	; Key: the samples go 02 ... [00] ... [01] ... 03 and never back, the first is 02, the last is 03, 00 appears at
	; most once (a one-dot window) and 01 at most twice (NESdev: a read on the dot the flag is set or the next one).
	JSR PrepNMI_TimingTests
TEST_NMI_Suppression_Loop:
	TXA
	LDY #0
	JSR VblSync_Plus_A
	JSR ClockslideFromWord
	.word 33143 ; the read lands across the VBlank flag. Measured: 02 01 01 03 03 03 03 03 03 03
	JSR EnableNMI ; This takes 31 cycles.
	JSR Clockslide_45
	LDA $2002
	ASL A ; Put VBlank flag in Carry
	TYA	; transfer Y to A (Y = 1 if the NMI happened)
	ROL A
	STA <$50,X
	JSR DisableNMI
	INX
	CPX #$0A
	BNE TEST_NMI_Suppression_Loop
	LDA <$50
	CMP #2
	BNE TEST_NMI_Suppression_Fail
	LDA <$59
	CMP #3
	BNE TEST_NMI_Suppression_Fail
	LDA #0
	STA <$5C ; previous rank
	STA <$5D ; 00 samples
	STA <$5E ; 01 samples
	LDX #0
TEST_NMI_Suppression_Check:
	LDY <$50,X
	LDA TEST_NMI_Suppression_Rank,Y
	CMP <$5C
	BCC TEST_NMI_Suppression_Fail ; went back
	STA <$5C
	CPY #0
	BNE TEST_NMI_Suppression_Not00
	INC <$5D
TEST_NMI_Suppression_Not00:
	CPY #1
	BNE TEST_NMI_Suppression_Not01
	INC <$5E
TEST_NMI_Suppression_Not01:
	INX
	CPX #$0A
	BNE TEST_NMI_Suppression_Check
	LDA <$5D
	CMP #2
	BCS TEST_NMI_Suppression_Fail
	LDA <$5E
	CMP #3
	BCS TEST_NMI_Suppression_Fail
	;; END OF TEST ;;
	LDA #1
	RTS
TEST_NMI_Suppression_Fail:
	JMP TEST_Fail
TEST_NMI_Suppression_Rank: ; by sample value 00, 01, 02, 03
	.byte 1, 2, 0, 3
;;;;;;;

TEST_NMI_Control:
	; STATUS: The 2C02 test with PAL waits: one PAL frame (Clockslide_PALFrame) for each NTSC frame wait, and 7462 CPU
	; cycles where VBlank has to be over (PAL VBlank is 70 scanlines, 7459.375 CPU cycles). Every check is the 2C02's;
	; NMI generation does not differ on the 2C07 (Visual 2C07). Not yet run on PAL hardware.
	; Special thanks to blargg. I'm pretty much just doing what they did here.
	LDA #$E8	; INX opcode
	STA $700
	LDA #$40	; RTI opcode
	STA $701
	JMP TEST_NMI_Control_Start
FAIL_NMI_Control1:
	JSR DisableNMI
	JMP TEST_Fail
TEST_NMI_Control_Start:
	;;; Test 1 [NMI Control]: The NMI should not occur when disabled. ;;;
	; The NMI *should* already be disabled (and it being enabled during the "WaitForVBlank" that happened before the jump here would be problematic...)
	; but let's test this anyway.
	LDX #0
	JSR Clockslide_PALFrame ; Wait 1 PAL frame.
	CPX #0
	BNE FAIL_NMI_Control1 ; If the NMI occurs, it will run INX, ... RTI. That would increment X to 1, thus failing the test.
	INC <ErrorCode
	
	;;; Test 2 [NMI Control]: The NMI should occur at VBlank when enabled. ;;;
	; Again, reaching this test would be impossible without the NMI occurring, so I have a hunch it won't fail this one.
	JSR ClockslideFromWord
	.word 7462 ; wait long enough that VBlank should be over: PAL VBlank is 70 scanlines (7459.375 CPU cycles).
	JSR EnableNMI
	; X is still zero.
	JSR Clockslide_PALFrame ; Wait 1 PAL frame.
	CPX #1
	BNE FAIL_NMI_Control1 ; If the NMI occurs, it will run INX, ... RTI. That would increment X to 1, thus passing the test.
	INC <ErrorCode

	;;; Test 3 [NMI Control]: The NMI should occur when enabled during VBlank, if the VBlank flag is enabled. ;;;
	JSR DisableNMI
	LDX #0
	JSR WaitForVBlank
	JSR Clockslide_PALFrame ; Wait 1 PAL frame.
	JSR EnableNMI
	CPX #1
	BNE FAIL_NMI_Control1
	INC <ErrorCode
	
	;;; Test 4 [NMI Control]: The NMI should NOT occur when enabled during VBlank, if the VBlank flag is disabled. ;;;
	JSR DisableNMI
	LDX #0
	JSR WaitForVBlank ; Wait for VBlank reads $2002, clearing the VBlank flag
	JSR EnableNMI
	JSR ClockslideFromWord
	.word 7462 ; wait long enough that VBlank should be over: PAL VBlank is 70 scanlines (7459.375 CPU cycles).
	CPX #0
	BNE FAIL_NMI_Control1
	INC <ErrorCode

	;;; Test 5 [NMI Control]: The NMI should NOT occur a second time if writing $80 to $2000 when the NMI flag is already enabled. ;;;
	JSR DisableNMI
	LDX #0
	JSR WaitForVBlank
	JSR Clockslide_PALFrame ; Wait 1 PAL frame.
	JSR EnableNMI
	JSR EnableNMI	
	CPX #1
	BNE FAIL_NMI_Control2	; If X was 2, then the NMI ran twice, thus failing the test.
	INC <ErrorCode
	
	;;; Test 6 [NMI Control]: (previous test) but the NMI was enabled going into VBlank. ;;;
	; The NMI is enabled going into this test.
	LDX #0
	JSR Clockslide_PALFrame ; Wait 1 PAL frame. (The NMI should happen in here)
	JSR EnableNMI ; (and the NMI should not happen a second time)
	CPX #1
	BNE FAIL_NMI_Control2	; If X was 2, then the NMI ran twice, thus failing the test.
	INC <ErrorCode
	
	;;; Test 7 [NMI Control]: The NMI should occur an additional time if you disable and then re-enable the NMI. ;;;
	JSR DisableNMI
	LDX #0
	JSR WaitForVBlank
	JSR Clockslide_PALFrame ; Wait 1 PAL frame.
	JSR EnableNMI
	JSR DisableNMI
	JSR EnableNMI ; (and the NMI should happen a second time)
	CPX #2
	BNE FAIL_NMI_Control2
	INC <ErrorCode
	
	;;; Test 8 [NMI Control]: The NMI is polled before the write cycle of STA. ;;;
	; This means that there is a gap between enabling the NMI and the NMI occurring:
	
	; STA $2000
	; LDX #$10
	; [NMI]	
	
	; In this example, the interrupt is polled before the write cycle of STA. (the NMI was not yet enabled)
	; Then the NMI was enabled when the interrupt is polled during `LDX #$10`
	; Therefore, the NMI occurs after the LDX, instead of immediately after the STA.
	
	JSR DisableNMI
	LDX #0
	JSR WaitForVBlank
	JSR Clockslide_PALFrame ; Wait 1 PAL frame.
	; Instead of using JSR EnableNMI, I need to actually write it all out here.
	LDA <PPUCTRL_COPY
	ORA #$80
	STA <PPUCTRL_COPY
	STA $2000
	LDX #$10
	CPX #$11
	BNE FAIL_NMI_Control2	; If the NMI happened before the LDX #$10 (incorrect), then X will be $11, thus failing the test.
	INC <ErrorCode

	;;; Test 9 [NMI Control]: The NMI is polled between write cycles of a read-modify-write instruction. ;;;

	JSR DisableNMI
	LDX #0
	JSR WaitForVBlank
	JSR Clockslide_PALFrame ; Wait 1 PAL frame.
	; Instead of using JSR EnableNMI, I need to actually write it all out here.
	LDA <PPUCTRL_COPY
	STA $2002 ; prepare the PPU IO Bus
	INC $2000
	LDX #$10
	CPX #$11
	BEQ FAIL_NMI_Control2	; If the NMI happened after the LDX #$10 (incorrect), then X will be $10, thus failing the test.
	
	;; END OF TEST ;;
	JSR DisableNMI
	LDA #1
	RTS
FAIL_NMI_Control2:
	JSR DisableNMI
	JMP TEST_Fail
;;;;;;;

TEST_NMI_VBL_End:
	; STATUS: DERIVED [2C07] The 2C02 test with the write stepped as in [VBlank end]: 8 samples 1.6 dots apart across
	; the end of VBlank (pre-render line 311), aimed at the next frame's VBlank (VblSync_Plus_A's last read of $2002
	; already cleared this frame's flag). Enabling the NMI while the VBlank flag is set causes an NMI at once; after
	; the flag is cleared it does not. Pending hardware: the CPU/PPU phase of a real console.
	JSR PrepNMI_TimingTests
	;;; Test 1 [NMI at VBlank end]: Tests the timing of the NMI as VBlank ends. ;;;
	; Loop 1 enables the NMI with JSR EnableNMI, loop 2 with STA $2000 followed by two NOPs (the interrupt is polled on
	; a different cycle). Each sample is 1 if the NMI happened. Key, for both loops: the first sample is 1, the last is
	; 0, they change once, and the two loops give the same samples (the NMI depends on the flag, not on the polling).
TEST_NMI_VBL_End_Loop:
	TXA
	LDY #0
	JSR VblSync_Plus_A
	JSR ClockslideFromWord
	.word 40660 ; the $2000 write in EnableNMI lands across the end of the next frame's VBlank
	JSR EnableNMI
	TYA
	STA <$50,X
	JSR DisableNMI
	INX
	CPX #$08
	BNE TEST_NMI_VBL_End_Loop
	LDX #0
TEST_NMI_VBL_End_Loop2:
	TXA
	LDY #0
	JSR VblSync_Plus_A
	JSR ClockslideFromWord
	.word 40675 ; the STA $2000 below lands where loop 1's write does
	LDA #$80
	STA $2000
	NOP
	NOP
	LDA #0
	STA $2000
	TYA
	STA <$60,X
	INX
	CPX #$08
	BNE TEST_NMI_VBL_End_Loop2
	; Check the key.
	LDA <$50
	BEQ TEST_NMI_VBL_End_Fail
	LDA <$57
	BNE TEST_NMI_VBL_End_Fail
	LDY #0
	LDX #0
TEST_NMI_VBL_End_Check:
	LDA <$50,X
	CMP <$60,X
	BNE TEST_NMI_VBL_End_Fail ; the two loops must agree
	CPX #0
	BEQ TEST_NMI_VBL_End_Next
	CMP <$4F,X
	BEQ TEST_NMI_VBL_End_Next
	INY
TEST_NMI_VBL_End_Next:
	INX
	CPX #$08
	BNE TEST_NMI_VBL_End_Check
	CPY #1
	BNE TEST_NMI_VBL_End_Fail
	;; END OF TEST ;;
	LDA #1
	RTS
TEST_NMI_VBL_End_Fail:
	JMP TEST_Fail
;;;;;;;

TEST_NMI_Disabled_VBL_Start:
	; STATUS: DERIVED [2C07] The 2C02 test with the write stepped as in [VBlank beginning]: 8 samples 1.6 dots apart
	; across the dot where the VBlank flag is set. Disabling the NMI before then prevents it; after, it has happened.
	; Pending hardware: the CPU/PPU phase of a real console.
	JSR PrepNMI_TimingTests
	;;; Test 1 [NMI disabled at VBlank]: Tests the timing of the NMI if disabled right as VBlank occurs. ;;;
	; Each sample is 1 if the NMI happened. Key: the first sample is 0, the last is 1, and they change once.
TEST_NMI_Disabled_VBL_Start_Loop:
	TXA
	LDY #0
	JSR VblSync_Plus_A
	JSR ClockslideFromWord
	.word 33142 ; the $2000 write in DisableNMI lands across the VBlank flag. Measured: 00 00 00 01 01 01 01 01
	JSR EnableNMI ; this takes 31 cycles
	JSR Clockslide_29
	JSR DisableNMI	; NMI disabled in 21 cycles.
	TYA
	STA <$50,X
	INX
	CPX #$08
	BNE TEST_NMI_Disabled_VBL_Start_Loop
	LDA <$50
	BNE TEST_NMI_Disabled_VBL_Start_Fail
	LDA <$57
	BEQ TEST_NMI_Disabled_VBL_Start_Fail
	LDY #0
	LDX #1
TEST_NMI_Disabled_VBL_Start_Check:
	LDA <$50,X
	CMP <$4F,X
	BEQ TEST_NMI_Disabled_VBL_Start_Same
	INY
TEST_NMI_Disabled_VBL_Start_Same:
	INX
	CPX #$08
	BNE TEST_NMI_Disabled_VBL_Start_Check
	CPY #1
	BNE TEST_NMI_Disabled_VBL_Start_Fail
	;; END OF TEST ;;
	LDA #1
	RTS
TEST_NMI_Disabled_VBL_Start_Fail:
	JMP TEST_Fail
;;;;;;;

PREP_SpriteZeroHit:
	LDA #0
	STA <dontSetPointer
	JSR PrintCHR
	.word $2001 ; At address $2001
	.byte $FC, $FF
	JSR ResetScroll
	JSR ClearPage2 ; $200 to $2FF = $FF
	JSR InitializeSpriteZero
	;    Ypos, CHR, Att, XPos
	.byte $00, $FC, $00, $08
	; InitializeSpriteZero updates the return address, returning here:
	JSR WaitForVBlank
	RTS
;;;;;;;



FAIL_Sprite0Hit_Behavior2:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

FAIL_ArbitrarySpriteZero1:
	JMP FAIL_ArbitrarySpriteZero

	
FAIL_ArbitrarySpriteZero:
FAIL_SprOverflow:
FAIL_MisalignedOAM:
FAIL_Address2004:
	JSR ClearOverscanNametable
	JSR WaitForVBlank
	JSR DisableRendering_S
	JSR EnableRendering_BG
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

VerifySprOverflowFlag:
	JSR sprOverflow_Setup
	JSR EnableRendering	; Enable both the background and sprites.
	JSR ClockslideFromWord ; wait long enough for these to render: PAL VBlank is 7459 CPU cycles (NTSC 2273, where the
	.word 7646             ; 2C02 version waits 3000): 727 cycles into the visible frame, as there.
	LDA $2002
	AND #$20 ; Bit 5 holds the sprite overflow flag
	RTS
;;;;;;;

TEST_SprOverflow_Behavior:
	;;; Test 1 [Sprite Overflow Behavior]: 9 sprites in a single scanline will set the Sprite Overflow Flag. ;;;
	JSR VerifySprOverflowFlag ; This is in a subroutine so I can re-use these bytes elsewhere.
	BEQ FAIL_SprOverflow
	INC <ErrorCode	
	
	;;; Test 2 [Sprite Overflow Behavior]: The Sprite Overflow Flag is NOT the same thing as the CPU's V flag. ;;;
	; The first emulator I ever made was making this mistake, ha! I doubt anybody is making this mistake, but I'll test for it anyway.
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; Set up OAM so objects 0 through 8 exist on scanline 1.
	CLV	; Clear CPU V flag
	JSR ClockslideFromWord ; wait long enough for these to render: PAL VBlank is 7459 CPU cycles (NTSC 2273, where the
	.word 7646             ; 2C02 version waits 3000): 727 cycles into the visible frame, as there.
	BVS FAIL_SprOverflow ; The CPU V flag should not have been set by the PPU.
	CLV	; Likewise, clearing this will not clear the Sprite Overflow flag.
	LDA $2002
	AND #$20 ; Bit 5 holds the sprite overflow flag
	BEQ FAIL_SprOverflow
	INC <ErrorCode		
	
	;;; Test 3 [Sprite Overflow Behavior]: 8 sprites in a single scanline will not set the Sprite Overflow Flag. ;;;
	LDA #$FF
	STA $200	; move sprite zero to Y=$FF (does not get rendered ever)
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; Set up OAM so objects 0 through 7 exist on scanline 1.
	JSR ClockslideFromWord ; wait long enough for these to render: PAL VBlank is 7459 CPU cycles (NTSC 2273, where the
	.word 7646             ; 2C02 version waits 3000): 727 cycles into the visible frame, as there.
	LDA $2002
	AND #$20 ; Bit 5 holds the sprite overflow flag. (in this case, not set because only 8 sprites existed on the busiest scanline)
	BNE FAIL_SprOverflow
	INC <ErrorCode		
	
	;;; Test 4 [Sprite Overflow Behavior]: Sprite evaluation occurs even if ONLY the background is rendering. ;;;
	JSR sprOverflow_Setup
	JSR EnableRendering_BG	; Enable just the background.
	JSR ClockslideFromWord ; wait long enough for these to evaluate (see above).
	.word 7646
	LDA $2002
	AND #$20 ; Bit 5 holds the sprite overflow flag
	BEQ FAIL_SprOverflow
	
	;; END OF TEST ;;
	JSR ClearOverscanNametable
	LDA #1
	RTS
;;;;;;;
	
sprOverflow_Setup:
	JSR ClearPage2
	LDA #0
	TAX
	TAY
SprOverflow_PrepLoop:
	LDA SpriteOverflowLUT, Y
	STA $200, X
	INX
	INY
	CPY #4
	BNE SprOverflow_Prep1
	LDY #0
SprOverflow_Prep1:
	CPX #4*9
	BNE SprOverflow_PrepLoop
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; Set up OAM so objects 0 through 8 exist on scanline 1.
	RTS
	
MisalignedOAM_Test:
	JSR WaitForVBlank
	JSR OAMDMAWithPage2
	JSR DisableRendering
	LDA #0
	JSR VblSync_Plus_A
	; Sync to dot 0 of VBlank

	LDA #0
	LDX #1
	STA $2002,X ; OAMADDR = 0 (indexed, so the dummy read is $2002). The 2C07's forced refresh moves OAMADDR every
	            ; frame even with rendering off (scanlines 265-310), so without this the DMA would start mid-OAM.
	JSR OAMDMAWithPage2
	JSR EnableRendering
	JSR ClockslideFromWord
	.word 6960 ; PAL: the $2003 writes after this land on scanline 0 dot 30, as in the 2C02 version (which waits 1816 of a 2273-cycle VBlank).
	RTS
;;;;;;;

FAIL_MisalignedOAM_Behavior_PLA:
	PLA
	PLA
FAIL_MisalignedOAM_Behavior:
	JMP FAIL_MisalignedOAM
	
TEST_MisalignedOAM_Evaluate:
	JSR Clockslide_500			; Wait long enough for the ppu to draw every scanline in which these objects are relevant.
	LDA $2002					; Read PPUSTATUS, putting the sprite overflow flag in bit 5.
	AND #$20 					; mask away bit 5. The result should be A = $20, since the sprite overflow flag *should* be set.
	BEQ FAIL_MisalignedOAM_Behavior_PLA
	INC <ErrorCode
	RTS
;;;;;;;
	

TEST_MisalignedOAM_Behavior:
	; Let's talk about what happens when you misalign the PPU OAM Address immediately before sprite evaluation, and how this changes the behavior of sprite evaluation.
	;;; Test 1 [Misaligned OAM Behavior]: Misaligned OAM can properly draw a sprite and trigger a sprite zero hit (Misaligned OAM "+1 behavior"). ;;;
	; This is genuinely the exact same test as [Arbitrary Sprite Zero] test 3.
	; Please see [Arbitrary Sprite Zero] test 3 for an explanation.
	; If this doesn't work, then it is assumed misaligned OAM is not working at all.
	JSR PREP_SpriteZeroHit			
	JSR MisalignedOAM_SpriteZeroTest
	LDX #1
	STX <ErrorCode
	CMP #1
	BNE FAIL_MisalignedOAM_Behavior
	; This test also relies on proper Sprite Overflow Flag emulation, so let's check that one too.
	JSR TEST_SprOverflow_Behavior
	LDX #1
	STX <ErrorCode
	CMP #1
	BNE FAIL_MisalignedOAM_Behavior
	INC <ErrorCode	
	
	;;; Test 2 [Misaligned OAM Behavior]: Misaligned OAM "+4 behavior" Offset by 1" ;;;	
	; Misaligned OAM should stay misaligned until an object's Y position is out of the range of this scanline, at which point the OAM address is incremented by 4 and bitwise ANDed with $FC.
	
	; In the "Arbitrary Sprite Zero" test, I said the following:
	; 	- Depending on how the evaluation goes, modify PPUOAMAddress. Typically increment by 1 or 4. (actually "it's complicated", but that's for a different test.)
	; Well, it's time for that test! 
	; When evaluating if the Y position of an object is in range for the scanline, if it *isn't* in range, the following occurs.
	; PPUOAMAddress += 4
	; PPUOAMAddress &= $FC
	;
	; This bitwise AND masks away the lower 2 bits, and it's not super common to see emulated.
	; If OAM is always aligned, then this bitwise AND seemingly does nothing.
	; In pretty much every case, the OAM address will always be a multiple of 4 when reading the Y position from OAM. 
	; Hence, adding 4 to this address when an object's Y position is not in range would take it to another multiple of 4. The bitwise AND makes no affect.
	;
	; However, if the OAM address is not a multiple of 4 when this bitwise AND occurs, it will re-align the PPUOAMAddress with a multiple of 4.
	; Let's study a series of bytes in OAM and how this works.
	; I'll put square brackets around the first object to be evaluated, and curly braces around the second. 
	; Try visualizing it like a Venn diagram: [A {B] C} where "A" are bytes exclusive to the first object, "B" are bytes that are shared, and "C" are bytes exclusive to the following object to get processed.
	; If OAM is aligned, it might look like this:
	; (OAM Address $80): [$80, $FC, $00, $08,] {$00, $FC, $00, $08}
	; Where that first byte ($80) is not in range of the scanline, so PPUOAMAddress is incremented by 4 and bitwise ANDed with $FC. The result takes PPUOAMAddress to $84.
	; This is the expected behavior, but when OAM is misaligned, these objects "overlap", sharing bytes. What would have been the X position of the first object becomes the Y position of the second:
	; If OAM is misaligned +1, it might look like this.
	; (OAM Address $80): $FF, [$80, $FC, $00, {$08,] $00, $FC, $00,} $08
	; Where that first byte ($80) is not in range of the scanline. The result still takes PPUOAMAddress to $84 (where the value is $08), due to the bitwise AND.
	; If OAM is misaligned +2, it might look like this.
	; (OAM Address $80): $FF, $FF, [$80, $FC, {$00, $08,] $00, $FC,} $00, $08
	; Where the same thing applies. PPUOAMAddress is now $84.
	; If OAM is misaligned +3, it might look like this.
	; (OAM Address $80): $FF, $FF, $FF, [$80, {$FC, $00, $08,] $00,} $FC, $00, $08
	; Where the same thing applies. PPUOAMAddress is now $84.
	; And if OAM is misaligned +4, then it's actually aligned again.
	; (OAM Address $80): $FF, $FF, $FF, $FF, [$80, $FC, $00, $08,] {$00, $FC, $00, $08}

	; So to recap, if the Y position *is* in range, then PPUOAMAddress is incremented by 1. Otherwise, add 4 to PPUOAMAddress, and mask away the lower 2 bits of PPUOAMAddress.
	; This results in OAM becoming "re-aligned".
	; And we can test for this behavior by misaligning OAM, having it get re-aligned, and then putting 9 objects on a single scanline to set the Sprite Overflow flag.
	; If the behavior does not match the console, then the data processed will intentionally be set up such that the sprite overflow flag doesn't get set.
	
	; To assist in debugging, the sprite evaluation for all of these tests will occur on scanline 0, and will be the first objects evaluated, starting at dot 65.
	
	; So to recap in simpler terms,
	; If the value read as the Y position *is* in range, just add 1 to the OAM address.
	; If the value read as the Y position is *not* in range, just add 4 to the OAM address and bitwise AND the OAM address with $FC.
	
	; Copy data from a look up table to address $280
	LDX #0
TEST_MisalignedOAM_P4_Y_1_Loop:
	LDA MisalignedOAM_Y_LUT_Off1,X
	STA $200, X
	INX
	CPX #41
	BNE TEST_MisalignedOAM_P4_Y_1_Loop
	JSR MisalignedOAM_Test		; Sync with (approximately) dot 0 of scanline 0.
	LDA #1			; The data we want to process in OAM first is at address 1.
	STA $2002		; Write this to $2002 to prime to PPU IO bus.
	LDX #$10		; We're going to write to $2003 with an offset, as a means to prevent the $2003 corruption.
	STA $20F3, X	; The dummy read prepared the CPU data bus with the value read from the PPU IO bus. Now the early write to $2003 will be #01, the same as the intended write.

	; Okay, so here's how these objects get processed.
	; OAM $01: [$00, $E3, $00, $00]
	; OAM $05: [$00, $E3, $00, $00]
	; OAM $09: [$00, $E3, $00, $00]
	; OAM $0D: [$00, $E3, $00, $00]
	; OAM $11: [$00, $E3, $00, $00]
	; OAM $15: [$00, $E3, $00, $00]
	; OAM $19: [$80]($FF, $FF, $00) This is NOT in range, so the only byte processed here is $80. PPUOAMAddress+=4; PPUOAMAddress&=$FC; (PPUOAMAddress is now $1C)
	; OAM $1C: [$00, $E3, $00, $00]
	; OAM $20: [$00, $E3, $00, $00]
	; OAM $24: [$00, $E3, $00, $00]
	; This puts 9 objects in range of this scanline, so the sprite overflow flag is set!
	; (By the way, the sprites are only processed like this for a single scanline. The rest of the scanlines, PPUOAMAddress will be $00 going into sprite evaluation.)
	JSR TEST_MisalignedOAM_Evaluate ; Evaluate and increment error code.
	
	;;; Test 3 [Misaligned OAM Behavior]: Misaligned OAM "+5 behavior" Offset by 1 ;;;
	; If Secondary OAM is full, instead of incrementing the OAM Address by 4 and bitwise ANDing with $FC, you should instead only increment the OAM address by 5.
	; Before this test, let's clear page 2 (with $FFs).
	JSR ClearPage2
	; Copy data from a look up table to address $220
	LDX #0
TEST_MisalignedOAM_P5_Y_1_Loop:
	LDA MisalignedOAM_Y_LUT_Off1_Full,X
	STA $200, X
	INX
	CPX #43
	BNE TEST_MisalignedOAM_P5_Y_1_Loop
	JSR MisalignedOAM_Test		; Sync with (approximately) dot 0 of scanline 0.
	LDA #1			; The data we want to process in OAM first is at address 1.
	STA $2002		; Write this to $2002 to prime to PPU IO bus.
	LDX #$10		; We're going to write to $2003 with an offset, as a means to prevent the $2003 corruption.
	STA $20F3, X	; The dummy read prepared the CPU data bus with the value read from the PPU IO bus. Now the early write to $2003 will be #01, the same as the intended write.

	; Okay, so here's how these objects get processed.
	; OAM $01: [$00, $E3, $00, $00]
	; OAM $05: [$00, $E3, $00, $00]
	; OAM $09: [$00, $E3, $00, $00]
	; OAM $0D: [$00, $E3, $00, $00]
	; OAM $11: [$00, $E3, $00, $00]
	; OAM $15: [$00, $E3, $00, $00]
	; OAM $19: [$00, $E3, $00, $00]
	; OAM $1D: [$00, $E3, $00, $00]
	; OAM $21: [$80]($FF, $FF, $FF, $FF) This is NOT in range, so the only byte processed here is $80. Secondary OAM is full, so add 5. PPUOAMAddress+=5; (PPUOAMAddress is now $26)
	; OAM $26: [$00, $E3, $00, $00]
	; This puts 9 objects in range of this scanline, so the sprite overflow flag is set!
	; (By the way, the sprites are only processed like this for a single scanline. The rest of the scanlines, PPUOAMAddress will be $00 going into sprite evaluation.)
	JSR TEST_MisalignedOAM_Evaluate ; Evaluate and increment error code.
	
	;;; Test 4 [Misaligned OAM Behavior]: Misaligned OAM "+4* behavior" Offset by 1 (* Only +1 with the X Position) ;;;
	; In the "Arbitrary Sprite Zero" test, I said the following:
	;	- There's actually some wild stuff going on with the X position, but that's for a different test.
	; Now it's time to test for this!
	; When evaluating the X position of an object, it also makes the same "in range of scanline" calculation that the Y position makes.
	; It's a bit confusing to explain, so let me recap.
	; In the "Arbitrary Sprite Zero" test, I specifically stated:
	; 	- for odd ppu cycles: read index "PPUOAMAddress" of OAM. Let's call the value read "S"...
	;	- for even cycles: Evaluate "S"...
	;	- STEP 1: Check that the Y position of this object is in range of this scanline.
	;		- If the current scanline number-"S" is positive, and less than 8 (or 16 if the sprites are using the 8 by 16 mode) then this object is in range for this scanline.
	;	- STEP 2 to 4: Read "S" as the CHR data, attributes, and X position respectively. 
	;
	; The exact same calculation used in "STEP 1" to determine if a value is in range of the scanline happens again in STEP 4.
	; Except now "S" holds the value of the X position.
	; So, if the current scanline number-"S" is positive, and less than 8 (or 16 if the sprites are using the 8 by 16 mode) then this object is in range for this scanline.
	; In the case of the Y position not being in range, you would add 4 to PPUOAMAddress and bitwise AND PPUOAMAddress with $FC.
	; However, in the case of the X position not being in range, you only add 1 to PPUOAMAddress, though you still bitwise AND with $FC.
	; In aligned OAM, this bitwise AND is never noticed, as adding 1 will align the PPUOAMAddress.
	; With misaligned OAM, we can detect this, again, by putting 9 objects on a scanline.	
	
	JSR ClearPage2
	LDX #0
TEST_MisalignedOAM_P4_1_Loop:
	LDA MisalignedOAM_LUT_Off1,X
	STA $200, X
	INX
	CPX #41
	BNE TEST_MisalignedOAM_P4_1_Loop
	JSR MisalignedOAM_Test		; Sync with (approximately) dot 0 of scanline 0.
	LDA #1			; The data we want to process in OAM first is at address 1.
	STA $2002		; Write this to $2002 to prime to PPU IO bus.
	LDX #$10		; We're going to write to $2003 with an offset, as a means to prevent the $2003 corruption.
	STA $20F3, X	; The dummy read prepared the CPU data bus with the value read from the PPU IO bus. Now the early write to $2003 will be #01, the same as the intended write.
	; Okay, so here's how these objects get processed.

	; OAM $01: [$00, $E3, $00, $80]
	; OAM $05: [$00, $E3, $00, $00]
	; OAM $09: [$00, $E3, $00, $00]
	; OAM $0D: [$00, $E3, $00, $00]
	; OAM $11: [$00, $E3, $00, $00]
	; OAM $15: [$00, $E3, $00, $00]
	; OAM $19: [$00, $E3, $00, $80] This X value ($80, at OAM address $20) is NOT in range. PPUOAMAddress+=1; PPUOAMAddress&=$FC; (PPUOAMAddress is now $1C)
	; OAM $1C: [$80]($E3, $FF, $FF) This Y values is also not in range, so add 4 (and bitwise AND with $FC)
	; OAM $20: [$00, $E3, $00, $00]
	; OAM $24: [$00, $E3, $00, $00]

	; This puts 9 objects in range of this scanline, so the sprite overflow flag is set!
	; (By the way, the sprites are only processed like this for a single scanline. The rest of the scanlines, PPUOAMAddress will be $00 going into sprite evaluation.)
	JSR TEST_MisalignedOAM_Evaluate ; Evaluate and increment error code.

	;;; Test 5 [Misaligned OAM Behavior]: Misaligned OAM "+4* behavior" Offset by 1, Second OAM Full, so OAMAddr +=5 (* Only +1 with the X Position) ;;;
	; If Secondary OAM is full, instead of incrementing the OAM Address by 1 and bitwise ANDing with $FC, you should instead only increment the OAM address by 5.
	; OAM will be offset by 1.
	JSR ClearPage2
	LDX #0
TEST_MisalignedOAM_P4_1F_Loop:
	LDA MisalignedOAM_LUT_Off1_Full,X
	STA $200, X
	INX
	CPX #42
	BNE TEST_MisalignedOAM_P4_1F_Loop
	JSR MisalignedOAM_Test		; Sync with (approximately) dot 0 of scanline 0.
	LDA #1			; The data we want to process in OAM first is at address 1.
	STA $2002		; Write this to $2002 to prime to PPU IO bus.
	LDX #$10		; We're going to write to $2003 with an offset, as a means to prevent the $2003 corruption.
	STA $20F3, X	; The dummy read prepared the CPU data bus with the value read from the PPU IO bus. Now the early write to $2003 will be #01, the same as the intended write.
	; Okay, so here's how these objects get processed.
	; OAM $01: [$00, $E3, $00, $00]
	; OAM $05: [$00, $E3, $00, $00]
	; OAM $09: [$00, $E3, $00, $00]
	; OAM $0D: [$00, $E3, $00, $00]
	; OAM $11: [$00, $E3, $00, $00]
	; OAM $15: [$00, $E3, $00, $00]
	; OAM $19: [$00, $E3, $00, $00]
	; OAM $1D: [$00, $E3, $00, $80] This X value ($80, at OAM address $20) is NOT in range. PPUOAMAddress+=1; PPUOAMAddress&=$FC; (PPUOAMAddress is now $20)
	; OAM $20: [$80]($E3, $FF, $FF, $FF) This Y values is also not in range and secondary OAM is full, so add 5 (PPUOAMAddress is now $25)
	; OAM $25: [$00, $E3, $00, $80]
	; This puts 9 objects in range of this scanline, so the sprite overflow flag is set!
	; (By the way, the sprites are only processed like this for a single scanline. The rest of the scanlines, PPUOAMAddress will be $00 going into sprite evaluation.)
	JSR TEST_MisalignedOAM_Evaluate ; Evaluate and increment error code.

	;;; Test 6 [Misaligned OAM Behavior]: Misaligned OAM "+4* behavior" Offset by 2 (* Only +1 with the X Position) ;;;
	; OAM will be offset by 2.
	JSR ClearPage2
	LDX #0
TEST_MisalignedOAM_P4_2_Loop:
	LDA MisalignedOAM_LUT_Off2,X
	STA $200, X
	INX
	CPX #39
	BNE TEST_MisalignedOAM_P4_2_Loop
	LDX #0
	LDY #$1E
	JSR MisalignedOAM_Test		; Sync with (approximately) dot 0 of scanline 0.
	LDA #2			; The data we want to process in OAM first is at address 2.
	STA $2002		; Write this to $2002 to prime to PPU IO bus.
	LDX #$10		; We're going to write to $2003 with an offset, as a means to prevent the $2003 corruption.
	STA $20F3, X	; The dummy read prepared the CPU data bus with the value read from the PPU IO bus. Now the early write to $2003 will be #01, the same as the intended write.
	; Okay, so here's how these objects get processed.
	; OAM $02: [$00, $E3, $10, $00]
	; OAM $06: [$00, $E3, $20, $00]
	; OAM $0A: [$00, $E3, $30, $00]
	; OAM $0E: [$00, $E3, $40, $00]
	; OAM $12: [$00, $E3, $50, $00]
	; OAM $16: [$00, $E3, $60, $00]
	; OAM $1A: [$00, $E3, $70, $00]
	; OAM $1E: [$00, $E3, $00, $80] This X value ($80, at OAM address $21) is NOT in range. PPUOAMAddress+=1; PPUOAMAddress&=$FC; (PPUOAMAddress is now $20)
	; OAM $20: [$00, $80, $00, $00] 
	; This puts 9 objects in range of this scanline, so the sprite overflow flag is set!
	; (By the way, the sprites are only processed like this for a single scanline. The rest of the scanlines, PPUOAMAddress will be $00 going into sprite evaluation.)
	JSR TEST_MisalignedOAM_Evaluate ; Evaluate and increment error code.

	;;; Test 7 [Misaligned OAM Behavior]: Misaligned OAM "+4* behavior" Offset by 3 (* Only +1 with the X Position) ;;;
	JSR ClearPage2
	LDX #0
TEST_MisalignedOAM_P4_3_Loop:
	LDA MisalignedOAM_LUT_Off3,X
	STA $200, X
	INX
	CPX #40
	BNE TEST_MisalignedOAM_P4_3_Loop
	LDX #0
	LDY #$1E
	JSR MisalignedOAM_Test		; Sync with (approximately) dot 0 of scanline 0.
	LDA #3			; The data we want to process in OAM first is at address 3.
	STA $2002		; Write this to $2002 to prime to PPU IO bus.
	LDX #$10		; We're going to write to $2003 with an offset, as a means to prevent the $2003 corruption.
	STA $20F3, X	; The dummy read prepared the CPU data bus with the value read from the PPU IO bus. Now the early write to $2003 will be #01, the same as the intended write.
	; Okay, so here's how these objects get processed.
	; OAM $03: [$00, $10, $00, $00]
	; OAM $07: [$00, $20, $00, $00]
	; OAM $0B: [$00, $30, $00, $00]
	; OAM $0F: [$00, $40, $00, $00]
	; OAM $13: [$00, $50, $00, $00]
	; OAM $17: [$00, $60, $00, $00]
	; OAM $1B: [$00, $70, $00, $00]
	; OAM $1F: [$00, $80, $00, $80] This X value ($80, at OAM address $21) is NOT in range. PPUOAMAddress+=1; PPUOAMAddress&=$FC; (PPUOAMAddress is now $20)
	; OAM $20: [$80]($00, $80, $FF, $FF) Secondary OAM is full, so instead of the PPUOAMAddress += 4, PPUOAMAddress &= $FC behavior, it's just the PPUOAMAddress +=5 behavior. (PPUOAMAddress is now $25)
	; OAM $25: [$00, $FF, $FF, $FF]
	; This puts 9 objects in range of this scanline, so the sprite overflow flag is set!
	JSR TEST_MisalignedOAM_Evaluate ; Evaluate and increment error code.
	
	;; END OF TEST ;;
	JSR ClearOverscanNametable
	JSR DisableRendering_S
	LDA #1
	RTS
;;;;;;;

	
MisalignedOAM_Y_LUT_Off1:
	; Misaligned +1, YPos not in range.
	.byte $FF
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $80, $FF, $FF      ; Y position is not in range of this scanline, so OAM will become re-aligned.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	
	; object 6 is processed as $80 (not in range)
	; object 7 is processed as $00, $E3, $00, $00
	; If this was aligned, it looks like this: (upwards of 8 in a single scanline)
	; $FF, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $80, $FF, $FF 
	; $00, $E3, $00, $00 
	; $00, $E3, $00, $00

	
MisalignedOAM_Y_LUT_Off1_Full:
	; Misaligned +1, YPos not in range. (OAM will be full before re-aligning, adding +5 due to a hardware error)
	.byte $FF
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $80, $FF, $FF, $FF, $FF; Y position is not in range of this scanline, so OAM+=5; (no bitwise stuff)
	.byte $00			     ; X position and Y position are both in range of this scanline.

	; object 8 is processed as $80 (not in range)
	; object 9 is processed as $00, $E3, $00, $00
	; If this was aligned, it looks like this: (upwards of 8 in a single scanline)
	; $FF, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $00, $E3, $00
	; $00, $80, $FF, $FF
	; $FF, $FF, $00
	
	
MisalignedOAM_LUT_Off1:
	; Misaligned +1
	.byte $FF
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $80 ; Y position is in range of this scanline, X position is not. (OAM++; OAM &= $FC) (That $80 is now the first byte processed for the next object)
	.byte $E3, $FF, $FF		 ; OAM is aligned again.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	; object 7 is processed as $80, $E3, $00, $00
	; object 8 is processed as $00, $E3, $00, $00
	; If this was aligned, it looks like this: (upwards of 8 in a single scanline)
	; $FF, $00, $E3, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $80, $E3, $FF, $FF
	; $00, $E3, $00, $00
	
MisalignedOAM_LUT_Off1_Full:
	; Misaligned +1 (OAM will be full before re-aligning, adding +5 due to a hardware error)
	.byte $FF
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $80 ; Y position is in range of this scanline, X position is not. (OAM++; OAM &= $FC) (That $80 is now the first byte processed for the next object)
	.byte $E3, $FF, $FF, $FF ; OAM is aligned, but since this object isn't in range, and 2nd OAM is full, due to a hardware bug OAM += 5.
	.byte $00, $E3, $00, $00 ; X position and Y position are both in range of this scanline.
	; object 7 is processed as $80, $E3, $FF, $FF, $FF (womp womp not in range. add 5 for some reason, ha!)
	; object 8 is processed as $00, $E3, $00, $FF
	; If this was aligned, it looks like this: (upwards of 8 in a single scanline)
	; $FF, $00, $E3, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $00, $E3, $00, $00
	; $80, $E3, $FF, $FF, $FF
	; $00, $E3, $00, $00
	
MisalignedOAM_LUT_Off2:
	; Misaligned +2
	.byte $FF, $FF
	.byte $00, $E3, $10, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $20, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $30, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $40, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $50, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $60, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $70, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $E3, $00, $80 ; Y position is in range of this scanline, X position is not. (OAM++; OAM &= $FC) (That second $00 is now the first byte processed for the next object)
	.byte $00	  			 ; OAM is aligned again.
	; object 8 is processed as $00, $00, $80, $00
	; If this was aligned, it looks like this: (upwards of 8 in a single scanline)
	; $FF, $FF, $00, $E3
	; $10, $00, $00, $E3
	; $20, $00, $00, $E3
	; $30, $00, $00, $E3
	; $40, $00, $00, $E3
	; $50, $00, $00, $E3
	; $60, $00, $00, $E3
	; $00, $00, $80, $00
	; $FF, $FF, $FF, $FF
	
MisalignedOAM_LUT_Off3:
	; Misaligned +3
	.byte $FF, $FF, $FF
	.byte $00, $10, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $20, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $30, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $40, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $50, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $60, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $70, $00, $00 ; X position and Y position are both in range of this scanline.
	.byte $00, $80, $00, $80 ; X position and Y position are both in range of this scanline.
	.byte $FF, $FF, $00
	; object 8 is processed as $80, $00, $80, $FF, $FF
	; object 9 is processed as $00, $FF, $FF, $FF
	; If this was aligned, it looks like this: (upwards of 8 in a single scanline)
	; $FF, $FF, $00, $E3
	; $00, $00, $00, $E3
	; $00, $00, $00, $E3
	; $00, $00, $00, $E3
	; $00, $00, $00, $E3
	; $00, $00, $00, $E3
	; $00, $00, $00, $E3
	; $00, $00, $00, $E3
	; $00, $80, $FF, $FF
;;;;;;;


SpriteOverflowLUT:
	.byte $00, $FC, $00, $80
	; Y position = $00 (top of screen)
	; Pattern = $FC (solid white square)
	; Attributes = 0 (not flipped, palette 0)
	; X Position = $80 (middle of screen)

Address2004_PreRevisionG:
	; Revision G PPUs added the ability to read from OAM DATA.
	; In order to prevent Pre-Revision-G PPUs from "failing" the test, we exit early.
	; However, we will write on screen that we didn't actually finish the test.
	LDA <RunningAllTests
	BNE Address2004_PreRevG_SkipMSG
	JSR Print_PreRevGBehavior
	JSR PrintTextCentered
	.word $2370
	.byte "    Missing reads from $2004.   ", $FF
Address2004_PreRevG_SkipMSG:
	LDA #$39 ; Success code "E", referring to a pre revision G ppu.
	RTS
;;;;;;;

FAIL_Address2004_PreRevG:
	JMP Address2004_PreRevisionG ; too far to branch.

FAIL_Address2004_Behavior:
	JSR WaitForVBlank
	JSR OAMDMAWithPage2
	JMP FAIL_Address2004

TEST_Address2004_Behavior:
	;;; Test 1 [Address $2004 behavior]: Writes to $2004 update OAM, and increment the OAM address by 1 ;;;
	JSR DisableRendering
	LDA #0
	STA <dontSetPointer
	JSR PrintCHR	; Put a white square at $2001 on the nametable.
	.word $2001
	.byte $FC, $FF	
	JSR ResetScrollAndWaitForVBlank
	LDA #0
	STA $2003 ; start the DMA at OAM[0]
	JSR OAMDMAWithPage2 ; run the OAM DMA, overwriting the whole thing with $FF
	LDA #0
	LDY #$FC
	STA $2004	; write $00 to OAM $00
	STY $2004	; write $FC to OAM $01
	STA $2004	; write $00 to OAM $02
	LDA #8
	STA $2004	; write $08 to OAM $03
	; Due to how writing here increments the OAM address, the sprite zero hit won't occur during scanline 1. It will instead occur during scanline 2, but this test is just checking to see if it happens at all.
	JSR EnableRendering
	JSR Clockslide_9000 ; PAL VBlank is 7459 CPU cycles
	LDA $2002
	AND #$40
	BEQ FAIL_Address2004_Behavior
	INC <ErrorCode
	
	;;; Test 2 [Address $2004 behavior]: Reads from $2004 give you a value in OAM, but do not increment the OAM address ;;;
	JSR ClearPage2
	LDA #$5A			; OAM address $00 will have the value $5A.
	STA $200			;
	LDA #$A5			; and OAM address $01 will have the value $A5.
	STA $201			;
	JSR WaitForVBlank
	LDA #0
	STA $2003 ; start the DMA at OAM[0]
	JSR OAMDMAWithPage2 ; run the OAM DMA with page 2.
	STA $2002 ; Prep buffer to check for Pre-Revision-G behavior.
	LDA $2004
	CMP #2
	BEQ FAIL_Address2004_PreRevG	; Pre revision G behavior detected! Let's get out of here.
	CMP #$5A
	BNE FAIL_Address2004_PreRevG	; You should read the value $5A. (This doesn't use a buffer like reading $2007)
	LDA $2004
	CMP #$5A
	BNE FAIL_Address2004_Behavior	; The OAM Address didn't increment, so the value will still be $5A.
	INC <ErrorCode
	
	;;; Test 3 [Address $2004 behavior]: Reads from the attribute bytes are missing bits 2 through 5 ;;;
	; If OAM is misaligned, it wouldn't be the attribute bytes in that case.
	; Specifically, address n+2, where "n" is a multiple of 4, is missing bits.
	; So, address $02, $06, $0A, $0E, $12, $16... and so on.
	JSR ClearPage2
	JSR WaitForVBlank
	LDA #0
	STA $2003 ; start the DMA at OAM[0]
	JSR OAMDMAWithPage2 ; run the OAM DMA with page 2.
	; OAM should be all $FFs, except the attribute addresses, which should be $E3.
	STA $2004 ; INC OAM address to $01
	STA $2004 ; INC OAM address to $02
	LDA $2004
	CMP #$E3
	BNE FAIL_Address2004_Behavior1	; You should read the value $E8
	INC <ErrorCode
	
	;;; Test 4 [Address $2004 behavior]: Reads from $2004 during PPU cycle 1 to 64 of a visible scanline (with rendering enabled) will always read $FF ;;;
	JSR ClearPage2
	LDA #$5A			; OAM address $00 will have the value $5A.
	STA $200			;
	LDA #$A5			; and OAM address $01 will have the value $A5.
	STA $201			;
	JSR WaitForVBlank
	JSR DisableRendering
	LDX #0
	LDA #0
	JSR VblSync_Plus_A
	; Sync to dot 0 of VBlank
	LDA #02
	STA $4014
	JSR EnableRendering
	JSR ClockslideFromWord
	.word 7468
	LDA $2004	; +9 cycles before the read.
	CMP #$FF
	BNE FAIL_Address2004_Behavior1	; Despite OAM Address $00 being $5A, the PPU is busy clearing Secondary-OAM to $FF, so this will read $FF.
	INC <ErrorCode
	
	;;; Test 5 [Address $2004 behavior]: Reads from $2004 during PPU cycle 1 to 64 of a visible scanline (with rendering disabled) does a regular read of $2004 ;;;
	JSR WaitForVBlank
	JSR DisableRendering
	LDA #0
	JSR VblSync_Plus_A
	; Sync to dot 0 of VBlank
	LDA #$5A
	STA $200 ; restore the OAM[0] byte cleared in test 3.
	LDA #0
	STA $2003 ; start the DMA at OAM[0]
	LDA #02
	STA $4014
	JSR DisableRendering
	JSR Clockslide_9000 ; reach visible scanlines after the 70-line PAL VBlank
	LDA #0
	STA $2003 ; the 2C07 advances OAMADDR during forced refresh; point at OAM[0] again.
	LDA $2004
	CMP #$5A
	BNE FAIL_Address2004_Behavior1	; Despite being between cycle 1 and 64 of a visible scanline, since rendering is disabled, it reads $5A.
	INC <ErrorCode
	BNE TEST_Address2004_Behavior_Continue ; branch always around the fail case.
	
FAIL_Address2004_Behavior1:
	JMP FAIL_Address2004

TEST_Address2004_Behavior_Continue:
	;;; Test 6 [Address $2004 behavior]: Writing to $2004 on a visible scanline increments the OAM address by 4 ;;;
	LDA #$8C
	STA $204 ; page-2 DMA source for OAM[4]
	JSR WaitForVBlank
	JSR DisableRendering
	LDA #0
	JSR VblSync_Plus_A
	; Sync to dot 0 of VBlank
	LDA #0
	STA $2003 ; start the DMA at OAM[0]
	LDA #02
	STA $4014
	JSR EnableRendering
	JSR Clockslide_9000 ; a visible PAL scanline, not the short VBlank offset
	LDA <$00	;+9	(This was originally a NOP, +6 cycles, but if your $2004 instruction doesn't have a delay of a few PPU cycles, then you would fail this test here, and that's not what this test is testing for.)
	LDA #0		;+6
	STA $2004	;+9 before write (+3 after). write with 20 ppu cycles until dot 0. (the CPU write occurs on dot 321 of the pre-render line)
	STA $2001   ;+9 before write, disable rendering with 8 ppu cycles before dot 0.
	LDA $2004
	CMP #$8C
	BNE FAIL_Address2004_Behavior1	; Despite being between cycle 1 and 64 of a visible scanline, since rendering is disabled, it reads $5A.
	INC <ErrorCode

	;;; Test 7 [Address $2004 behavior]: Writing to $2004 on a visible scanline doesn't write to OAM ;;;
	; leeching off the results of the previous test...
	; PPUOAMAddress is currently 4
	LDX #4
TEST_Address2004_Behavior_Loop:
	STA $2004	; A = $8C, so we're overwriting all of OAM with $8C right now.
	INX
	BNE TEST_Address2004_Behavior_Loop
	; OAM Address is now 0.
	; If writing during rendering wrote a value, this address would be $00. Instead, it should be $5A.
	LDA $2004
	CMP #$5A
	BNE FAIL_Address2004_Behavior1
	INC <ErrorCode

	;;; Test 8 [Address $2004 behavior]: Reads from $2004 during PPU cycle 65 to 256 of a visible scanline (with rendering enabled) reads from the current OAM address, which is changing every other ppu cycle.;;;
	JSR WaitForVBlank
	JSR DisableRendering
TEST_Address2004_Behavior_loop:			; Set up page 2 so every value is essentially the index into OAM
	TXA									; (As mentioned in test 3, the attribute bytes will be missing a few bits, but that's fine.)
	STA $200, X							; We're going to read from OAM in the middle of evaluation to see where the OAM address is.
	INX									;
	BNE TEST_Address2004_Behavior_loop	;
		LDA #$5A
		STA $200 ; non-zero OAM[0] marker
	LDA #0
	JSR VblSync_Plus_A
	; Sync to dot 0 of VBlank
	LDA #02
	STA $4014
	JSR EnableRendering
	; Aim for about dot 130 of PAL scanline 0.
	JSR ClockslideFromWord
	.word 7460
		LDA #0
		STA $2003 ; 2C07 forced refresh advanced OAMADDR
	LDA $2004
	BEQ FAIL_Address2004_Behavior1	; It definitely shouldn't be $00.
	CMP #$FF
	BEQ FAIL_Address2004_Behavior1	; Since it's inconsistent between CPU/PPU clock alignments, (and probably different on different console revisions) we'll simply just check that it isn't FF.
	INC <ErrorCode

	;;; Test 9 [Address $2004 behavior]: Reads from $2004 during PPU cycle 256 to 320 of a visible scanline (with rendering enabled) reads $FF again. ;;;
	JSR WaitForVBlank
	JSR DisableRendering

	LDA #0
	JSR VblSync_Plus_A
	; Sync to dot 0 of VBlank
	LDA #02
	STA $4014
	JSR EnableRendering
	; Aim for the middle of the empty sprite slots' fetches (dots 265-320) of a visible scanline.
	; The wait was 7560, 100 cycles more than test 8's 7460. The 2C02 version separates the two reads by 60 cycles = 180
	; dots (dot 130 -> dot 310); on the 2C07 a CPU cycle is 3.2 dots, so 100 cycles moved the read 320 dots, to the sprite
	; evaluation of the NEXT scanline (measured: dot 127 of scanline 5, where it reads OAM[$24], an evaluation
	; byte). 7505 puts it 176 dots earlier, on dot 291 of scanline 4: sprite slot 4 of the fetches. Only sprite 1
	; (Y = 4) is in range there, so slots 1-7 are empty and read $FF.
	; The VBlank sync's dot phase is not validated on hardware (see VblSync_Plus_A); the window allows +-27 dots.
	JSR ClockslideFromWord
	.word 7505
	LDA $2004
	CMP #$FF ; As on the 2C02: from the pre-render line on, the 2C07's sprite engine is the 2C02's (Quietust's Visual 2C07).
	BNE FAIL_Address2004_Behavior2	; This reads $FF. (I'll need to look into why, but I know this is the case.)
	INC <ErrorCode
	
	;;; Test A [Address $2004 behavior]: Writing to $2004 on a visible scanline increments the OAM address by 4, and bitwise AND the OAM Address with $FC ;;;
	LDA #$8C
	STA $204
	JSR WaitForVBlank
	JSR DisableRendering
	LDA #0
	JSR VblSync_Plus_A
	; Sync to dot 0 of VBlank
	LDA #0
	STA $2003 ; start the DMA at OAM[0]
	LDA #$02
	STA $4014
	JSR EnableRendering
	JSR ClockslideFromWord
	.word 9000 ; PAL: reach a real visible scanline
	LDX #5
	LDA #1
	STA $2006, X ; PPU OAM is 1.	
	LDA #0		;+6
	STA $2004	;+9 before write (+3 after). write with 20 ppu cycles until dot 0. (the CPU write occurs on dot 321 of the pre-render line)
	STA $2001   ;+9 before write, disable rendering with 8 ppu cycles before dot 0.
	LDA $2004
	CMP #$8C
	BNE FAIL_Address2004_Behavior2	; Despite being between cycle 1 and 64 of a visible scanline, since rendering is disabled, it reads $5A.

	;; END OF TEST ;;
	JSR ClearOverscanNametable
	JSR WaitForVBlank
	JSR DisableRendering_S
	LDA #$41 ; Success code "G", referring to revision G PPU (or later) behavior.
	RTS
;;;;;;;

	
FAIL_Address2004_Behavior2:
	JMP FAIL_Address2004

FAIL_APURegActivation_RevE:
	JMP Stress2004_RevE

FAIL_APURegActivation_Pre:
	LDA #1
	STA <ErrorCode
	JMP TEST_Fail

TEST_APURegActivation:
	; STATUS: UNVERIFIED [OPENBUS][2A07] Tests 5-7 run in a 2A07 form that needs no DMC DMA (STA (zp),Y executed at $3FFE, see test 5). Their keys are the published 2A03 tables, assumed unchanged on the 2A07; no 2A07 measurement exists. Pending hardware.
	;;; Test 1 [APU Register Activation]: Pre-requisite test suite: Does DMA affect the data bus? Is DMC DMA timing accurate? Is open bus accurate enough for this test? How about PPU IO Bus? What about the PPU Read buffer? OAM DATA? ;;;
	; For the purposes of debugging, you can press select to show the debug menu. Address $50 will be labeled 00 to 05 based on which pre-requisite it fails.

	JSR DMASync	; 2A07 form: does the DMA sync work (opcode-from-open-bus sync, see TEST_InstructionTiming)?
	LDA $07EA	; 0 = the sync worked, $FF = it gave up. This is written before the main menu loads when resetting the ROM. If you aren't passing this test (and using save-states), you'll need to reboot the ROM to update this value.
	BNE FAIL_APURegActivation_Pre ; Fail if the sync failed.
	INC <$50 ; for debugging.
	
	JSR TEST_DMA_Plus_2007R
	CMP #1
	BNE FAIL_APURegActivation_Pre ; Fail if DMC DMA timing is off.
	INC <$50 ; for debugging.


	JSR DisableRendering ; This is mostly used to make sure OAM Corruption doesn't conflict with the OAMDATA pre-test.
	LDY #$10	 ; A copy of Open Bus test 3. If this fails, then open bus isn't reliable enough for this test.
	LDA $50F8, Y ; This offset changes the high byte of the value read, but not the data bus.
	CMP #$50
	BNE FAIL_APURegActivation_Pre ; Fail if open bus is faked.
	INC <$50 ; for debugging.

	LDA #$5A
	STA $2002
	LDA #0
	LDA $3000 ; use a mirror to test for mirrors too.
	CMP #$5A
	BNE FAIL_APURegActivation_Pre ; Fail if PPU IO open bus doesn't exist.
	INC <$50 ; for debugging.

	JSR WriteToPPUADDRWithByte
	.byte $2C, $00
	.byte $A5, $FF
	JSR ReadPPUADDRFromWord
	.byte $2C, $00
	CMP #$A5
	BNE FAIL_APURegActivation_Pre ; Fail if the PPU read buffer isn't working.
	INC <$50 ; for debugging.

	LDX #0 ; Check 
	STX $2003
	LDA #$5A
	STA $2004
	TXA
	LDX #1
	STA $2002
	STA $2002, X ; safely write to $2003 without the risk of OAM Corruption.
	LDA #$A5
	STA $2002
	TXA
	LDA $2004 ; Read from OAMDATA
	CMP #$A5 ; Pre-revision-G PPU behavior!
	BEQ FAIL_APURegActivation_RevE
	CMP #$5A
	BNE FAIL_APURegActivation_Pre

	JSR ResetScrollAndWaitForVBlank
	LDA #02
	STA <ErrorCode
	; It is assumed we're not going to crash when running this test if those 2 pre-requisites pass.

	;;; Test 2 [APU Register Activation]: Controller ports only have bit 0 and open bus. And maybe the Famicom microphone. ;;;
	; Confirm there's nothing odd going on with the controller ports.
	LDA $4016
	AND #$BA
	BNE FAIL_APURegActivation0
	LDA $4017
	AND #$BE
	BNE FAIL_APURegActivation0
	INC <ErrorCode

	;;; Test 3 [APU Register Activation]: Pre-requisite test: Reading from $4015 clears the "frame interrupt flag" ;;;
	SEI ; If the frame interrupt flag is set without this, we can get stuck in an infinite loop of BRK instructions.
	LDA #0
	STA $4017	; enable the frame counter Interrupt flag.
	JSR ClockslideFromWord
	.word 33298 ; PAL frame IRQ
	LDA $4015
	AND #$40
FAIL_APURegActivation_slide:
	BEQ FAIL_APURegActivation0 ; If this fails, the Frame interrupt flag wasn't set? Likely not implemented.
	LDA $4015
	AND #$40
	BNE FAIL_APURegActivation0 ; If this fails, the Frame interrupt flag wasn't cleared when read last time.
	INC <ErrorCode
	BNE APURegActivation_Continue
	
FAIL_APURegActivation0:
	JMP FAIL_APURegActivation
	
APURegActivation_Continue:
	;;; Test 4 [APU Register Activation]: Can the DMA read from the APU registers when the CPU is not executing out of page $40? ;;;	
	; What's happening here?
	; The 2A03 chip (the CPU/APU) has an address bus.
	; Inside the 2A03 chip are 3 address buses: The 6502 Address Bus, the DMC Address Bus, and the OAM Address bus. On any given cycle, only one of these buses can be chosen to connect to the 2A03 address bus.
	; Here's the catch. Reading from the APU registers requires the 6502 address bus to be in the range of $4000 through $401F.
	; If the OAM address bus is pointing to $4000 through $401F, and the 6502 address bus isn't, then the OAM DMA will only read open bus from that range.
	; Which can be detected, since reading $4015 clears the interrupt flag.
	;
	; This test will write $40 to $4014, running an OAM DMA that will read from address $4000 to $40FF.
	; However, the APU registers are not active! So every value read by the DMA will be open bus.
	JSR ClockslideFromWord
	.word 33298 ; PAL frame IRQ
	LDA #$40
	STA $4014	; OAM DMA with page $40.
	; This does *NOT* read from the APU Registers!
	LDA $4015
	AND #$40
	BEQ FAIL_APURegActivation_slide ; If this fails, the DMA read from the APU registers.
	INC <ErrorCode

	;;; Test 5 [APU Register Activation]: Can your emulator handle the wacky setup required to determine if the APU registers are active due to the 6502 address bus? (this could cause a crash) ;;;
	; Oh- also don't press anything on controller 2 during this test. thanks. :)
	;
	; Okay, so what is this test all about?
	; The APU registers (from $4000 to $4017) are not always accessible.
	; For instance, in the previous test, the APU registers were not active, so that OAM DMA didn't read any of the values there.
	; So "What activates the APU registers?" I hear you asking.
	; These registers are active when the 6502 Address Bus is in the range $4000 through $401F.
	; So if the 6502 address bus was within that range, and a OAM DMA were to occur, then the OAM DMA would be able to read the APU registers.
	;
	; Here's the plan. (Special thanks to lidnariq and Fiskbit)
	; Execute STA $4014 (A = $40) from address $3FFE. (The 6502 address bus will be $4001 when the OAM DMA occurs. Follow that up with a BRK from address $4001.)
	; In order to make this work, we need the PPU IO bus to be $8D, the PPU Buffer to be $14, and Open Bus to be $40
	; So, the order of operations here is: 
	; Prepare PPU buffer with $14. (some writes to $2006, a write to $2007, more writes to $2006, and a read from $2007)
	; Prepare PPU IO bus with $8D. Write $8D to $2002.
	; Now, when we execute this:
	; [$3FFE = $8D] [$3FFF = $14] [DMC DMA! Overwrite data bus with $40] [$4000 = $40] [OAM DMA!]
	; Which will result in an OAM DMA where the 6502 Data bus is in-fact from the range $4000 to $401F, so the OAM DMA *will* read from all the registers.
	; And then the final value of the data bus will be $00, so the following instruction will be BRK.
	;
	; We'll also want to set up one of the audio channels to be playing, so the results are slightly more interesting. (so APU STATUS has a value other than $00) How about the triangle channel?
	;
	; Okay, but what's actually happening during the DMA? 
	;
	; The only registers at play here are $4015, $4016, and $4017, since those are the only readable APU registers.
	; However, since the APU registers are active (the 6502 address bus is within $4000 through $401F) the OAM DMA can read from the APU registers.
	; Surprisingly, these registers have mirrors every $20 bytes. They just aren't normally accessible, as the 6502 address bus would typically be out of the $4000 through $401F range when trying to read these mirrors.
	; However, with the APU registers active, the OAM DMA will be able to read from the APU registers and their mirrors.
	; Here's the values that are expected to be put in OAM by this DMA.
	;
	;      00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F
	;    ┌─────────────────────────────────────────────────┐
	; 00 │ 50 50 40 50 50 50 40 50 50 50 40 50 50 50 40 50 │ ; The value of $50 is left over from the data bus. The attribute bytes from OAM are missing bit 4 though, so they are read back as $40.
	; 10 │ 50 50 40 50 50 44 41 40 40 40 40 40 40 40 40 40 │ ; The $40's are the left over data bus. The value of $44 is the frame interrupt flag + the triangle channel from reading address $4015 (APU Status).
	; 20 │ 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 │ ; Referring to the above line, the $41 is open bus + reading controller 1, and $40 is open bus + controller 2. (this line is just open bus)
	; 30 │ 40 40 40 40 40 04 01 00 00 00 00 00 00 00 00 00 │ ; This time, the frame interrupt flag is cleared, which clears bit 6 of open bus in future reads. The $01 is just controller 1. Controller 2 is still $00.
	; 40 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │ ; All zeroes. Just open bus.
	; 50 │ 00 00 00 00 00 04 01 00 00 00 00 00 00 00 00 00 │ ; Just the triangle playing with APU STATUS, and controller 1 being $01, which will never change. Controller 2 is still $00, and will never change.
	; 60 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │
	; 70 │ 00 00 00 00 00 04 01 00 00 00 00 00 00 00 00 00 │ ; Actually a correction about controller 2. If your DMA somehow reads the controller port extra times, this will eventually be $01, as will every open bus byte following it.
	; 80 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │ ; If that does occur, you likely won't execute a BRK instruction on address $4001. It would likely be ORA <$01, X, which I could use to manipulate the data bus into an RTS!
	; 90 │ 00 00 00 00 00 04 01 00 00 00 00 00 00 00 00 00 │
	; A0 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │
	; B0 │ 00 00 00 00 00 04 01 00 00 00 00 00 00 00 00 00 │
	; C0 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │
	; D0 │ 00 00 00 00 00 04 01 00 00 00 00 00 00 00 00 00 │
	; E0 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │
	; F0 │ 00 00 00 00 00 04 01 00 00 00 00 00 00 00 00 00 │
	;    └─────────────────────────────────────────────────┘

	; 2A07 form of the setup. The 2A03 version executes STA $4014 from $3FFE and needs a DMC DMA to put the operand's
	; high byte ($40) on the bus during the instruction; a 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so that byte can never appear there. This form needs no DMC DMA at all:
	;   [$3FFE = $91 from the PPU I/O latch: STA (zp),Y] [$3FFF = $50 from the $2007 read buffer] [<$50/$51> = $4014, Y = 0]
	; The write to $4014 is the instruction's last cycle, so the next cycle is the opcode fetch at $4000: the OAM DMA
	; halts the CPU there, with the 6502 address bus at $4000 (the 2A03 version has it at $4001; both are in
	; $4000-$401F, which is all the activation needs). A = $50, so the DMA reads page $50 (open bus) as before, and the
	; data bus holds $50 from the write when it starts. After the DMA the bus holds $00 and the repeated fetch is a BRK.
	; KEY: the table above is the published 2A03 measurement. No 2A07 measurement exists (Fiskbit's open question in
	; t=25939: is the $4000-$401F behaviour unchanged on the 2A07?); it is assumed unchanged. Pending hardware.
	; Step 1: Set up the IRQ function
	LDA #$68	;PLA
	STA $600	; - PLA (Flags from BRK)
	STA $601	; - PLA (Return address Low)
	STA $602	; - PLA (Return Address High)
	LDA #$A9	; LDA #Immediate
	STA $603	; - LDA
	STA $604	; - #$A9
	LDA #$60	;RTS
	STA $605	; - RTS (to the JSR inside this test.)
	; The DMA runs eight times, and each time 32 bytes of OAM are copied to $500-$5FF right after it, in the same
	; VBlank (OAM addresses $00, $20, ..., $E0): there is not enough VBlank before scanline 265 to copy all 256 at once.
	LDA #0
	STA <$5E
TEST_ARA5_Pass:
	; Step 2: Begin playing the triangle channel. (so APU Status isn't $00) This also turns the DMC off.
	LDA #4
	STA $4015	; enable the triangle channel
	LDA #$F0
	STA $400B
	LDA #$FF
	STA $4008
	; Step 2b: the frame interrupt flag must be set when the DMA reads $4015 (the $44 in row 10). Test 4's last read
	; cleared it; one full PAL frame-counter sequence sets it again (IRQs are still inhibited by test 3's SEI).
	JSR ClockslideFromWord
	.word 33298 ; PAL frame IRQ
	; Step 3: strobe controllers and read controller 1 eight times.
	JSR ReadController1
	; Controller 2 was also strobed, but never read.
	; Step 4: Put $50 (the operand: the zero page pointer's address) in the PPU read buffer.
	JSR WaitForVBlank
	JSR DisableRendering ; the OAM copy (TEST_ARA_CopyOAM32) needs rendering off.
	LDA #0
	LDX #1
	STA $2002,X          ; OAMADDR = 0: the 2C07's forced refresh (scanlines 265-310) of earlier frames has moved it, and the DMA writes from wherever it is.
	JSR WriteToPPUADDRWithByte
	.byte $2C, $00
	.byte $50, $FF
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007 ; Prep the buffer with the value of $50 written to PPU $2C00
	JSR ResetScroll
	; Step 5: the pointer, and $91 (STA (zp),Y) in the PPU IO bus.
	LDA #$14
	STA <$50
	LDA #$40
	STA <$51	; <$50/$51> = $4014
	LDA #$91
	STA $2002
	; Step 6: Try and prevent a crash with incorrect results of the test.
	LDX #0 	 ; If (instead of BRK) you run: ORA <$01, X...
	LDA #$60 ; This value of $60 will be put on the data bus. an RTS instruction!
	STA <$01 ; And since the BRK jumps to a function loading the value of A with $A9, we can check for this after the test.
	; Step 6b: the byte left on the bus by the DMA is executed at $4000. The key expects $00 (BRK), but no 2A07 has
	; run this, so the other plausible outcomes are steered into the same BRK instead of a crash on the hardware run:
	;   $04 (no joypad read by the DMA): NOP <$04, then the byte read from <$04> is the next opcode: <$04> = $00.
	;   $01 (only joypad 1 read):        ORA ($01,X), pointer <$01/$02> = $0060, then <$60> is the next opcode: $00.
	;   $50 (no register read at all):   BVC with V set is not taken, and again at $4002-$4014; $4016 then reads $41
	;                                    (controller 1 returns 1 after 8 reads): EOR ($40,X), pointer <$40/$41> = $0042,
	;                                    then <$42> is the next opcode: $00.
	; Every one of these returns here with A = $A9 and fails test 6 on the table instead.
	LDA #0
	STA <$04
	STA <$02
	STA <$60
	STA <$41
	STA <$42
	LDA #$42
	STA <$40
	; Step 7: run it. No timing is involved.
	LDY #0
	LDA #$50
	BIT <$51	; <$51> = $40: sets V (see step 6b). STA (zp),Y and JSR leave the flags alone.
	JSR $3FFE	; STA ($50),Y from the PPU registers' mirrors, then the OAM DMA on the $4000 fetch, then BRK.
	CMP #$A9
	BEQ TEST_ARA5_BRKed
	JMP FAIL_APURegActivation
TEST_ARA5_BRKed:
	; Still in the VBlank of the DMA, before the 2C07's forced OAM refresh (scanline 265 on): copy this pass's 32 OAM
	; bytes to RAM. Reading OAM later would depend on the refresh and on OAM decay with rendering off, which are not
	; established for the 2C07 (NESdev forum "PAL NES, sprite evaluation and $2004 reads/writes").
	LDA <$5E
	ASL A
	ASL A
	ASL A
	ASL A
	ASL A
	JSR TEST_ARA_CopyOAM32
	INC <$5E
	LDA <$5E
	CMP #8
	BEQ TEST_APURegActivation_5OK
	JMP TEST_ARA5_Pass
TEST_APURegActivation_5OK:
	INC <ErrorCode
	
	;;; Test 6 [APU Register Activation]: The DMA can read from the APU registers when the CPU is executing out of page $40? ;;;
	; Step 1: copy OAM to page 2.
	; $500-$5FF holds OAM as the eight passes of test 5 read it.
	; Instead of making a 256 byte large look up table, I'm going to check each row individually. The result should match that table printed out above in the Test 4 description.
	; X already equals zero.
	LDY #0
	LDX #0
TEST_APURegActivation_Eval_0:		;
	LDA $500,X						; Read the value copied from OAM
	CMP TEST_APURegActivation_E0Key, Y; This row should be a pattern of 50 50 40 50
	BNE FAIL_APURegActivation		; If it's not a match, you fail
	INY								; INY for the key here.
	TYA								; clamp Y to 0 through 3
	AND #3							; ^
	TAY								; ^
	INX								; If it IS a match, check the next one.
	CPX #$15						; Loop this through address $214
	BNE TEST_APURegActivation_Eval_0;
	LDA $500,X						; Read the value copied from OAM at $215
	CMP #$44						; This should be 44
	BNE FAIL_APURegActivation		; If it's not $44, you fail
	INX								; Increment X for the next one.
	LDA $500,X						; Read the value copied from OAM at $216
	AND #$FB						; Mask away the famicom's microphone bit.
	CMP #$41						; This should be 41
	BNE FAIL_APURegActivation		; If it's not $41, you fail
	INX								; Increment X for the next one.
TEST_APURegActivation_Eval_1:		;
	LDA $500,X						; Read the value copied from OAM
	CMP #$40						; This row should be all $40's
	BNE FAIL_APURegActivation		; If it's not $40, you fail
	INX								; If it IS $40, check the next one.
	CPX #$35						; Loop this through address $234
	BNE TEST_APURegActivation_Eval_1;
	; From here on out, it's a pattern of $04, $01, and $00 repeated $1E times
	LDY #0
TEST_APURegActivation_Eval_2:
	CPY #2
	BPL TEST_APURegActivation_Skip0401
	LDA $500,X						; Read the value copied from OAM at $2_5
	CMP #$04						; This should be 04
	BNE FAIL_APURegActivation		; If it's not $04, you fail
	INX								; Increment X for the next one.
	LDA $500,X						; Read the value copied from OAM at $2_6
	AND #$FB						; Mask away the famicom's microphone bit.
	CMP #$01						; This should be 01
	BNE FAIL_APURegActivation		; If it's not $01, you fail
	INX								; Increment X for the next one.	
	LDY #02							; It probably should have been INY's for neatness, but this saves 2 CPU cycles.
TEST_APURegActivation_Skip0401:
	LDA $500,X						; Read the value copied from OAM
	CMP #$00						; This should be 00
	BNE FAIL_APURegActivation		; If it's not $00, you fail
	INY								; Increment Y for the next one.
	CPY #$20
	BNE TEST_APURegActivation_SkipResetY	; if Y=20, reset to 0, so we can check for the "$04 $01"
	LDY #0
TEST_APURegActivation_SkipResetY:
	INX								; Increment X for the next one.	
	BNE TEST_APURegActivation_Eval_2
	; Bravo!
	INC <ErrorCode
	BNE TEST_APURegActivation_Continue

TEST_ARA_CopyOAM32:
	; In: A = an OAM address (a multiple of $20). Copies the 32 OAM bytes from there to $500+A. Rendering is off.
	; The last read of a pass is on scanline 257, well before the forced refresh at 265.
	; 20 CPU cycles per byte. OAMADDR is written through $2002,X so the indexed write's dummy read is $2002, not $2003.
	TAY
	LDX #1
	STA $2002,X
	LDX #32
TEST_ARA_CopyOAM32_Loop:
	LDA $2004
	STA $500,Y
	STA $2004 ; writes the same byte back, to advance OAMADDR
	INY
	DEX
	BNE TEST_ARA_CopyOAM32_Loop
	RTS
;;;;;;;

FAIL_APURegActivation:
	LDA #$40
	STA $4017
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_APURegActivation_E0Key:
	.byte $50, $50, $40, $50


TEST_APURegActivation_Continue:
	;;; Test 7 [APU Register Activation]: If the APU registers are active, there will be bus conflicts if the OAM DMA is reading from outside of open bus. ;;;
	; The setup here is incredibly similar, except the OAM DMA will occur on page 2 instead, after clearing page 2 to be 50% FFs and 50% 00s.
	;
	; Here's how OAM should end up after this test:
	;
	;      00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F
	;    ┌─────────────────────────────────────────────────┐
	; 00 │ FF FF E3 FF FF FF E3 FF FF FF E3 FF FF FF E3 FF │ ; The value of $FF is because we cleared page 2 with a bunch of FFs. (and the $E3 is the attribute bytes)
	; 10 │ FF FF E3 FF FF 24 E3 FF FF FF E3 FF FF FF E3 FF │ ; The value of $24 is the triangle channel from reading address $4015, + bit 5 is set from the byte on page 2.
	; 20 │ FF FF E3 FF FF FF E3 FF FF FF E3 FF FF FF E3 FF │ ; Amusingly, it does not appear to have read the controllers, despite the reads from APU_STATUS.
	; 30 │ FF FF E3 FF FF 24 E3 FF FF FF E3 FF FF FF E3 FF │
	; 40 │ FF FF E3 FF FF FF E3 FF FF FF E3 FF FF FF E3 FF │
	; 50 │ FF FF E3 FF FF 24 E3 FF FF FF E3 FF FF FF E3 FF │
	; 60 │ FF FF E3 FF FF FF E3 FF FF FF E3 FF FF FF E3 FF │
	; 70 │ FF FF E3 FF FF 24 E3 FF FF FF E3 FF FF FF E3 FF │
	; 80 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │ ; I made the second half of page 2 all zeroes.
	; 90 │ 00 00 00 00 00 04 00 00 00 00 00 00 00 00 00 00 │
	; A0 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │
	; B0 │ 00 00 00 00 00 04 00 00 00 00 00 00 00 00 00 00 │
	; C0 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │
	; D0 │ 00 00 00 00 00 04 00 00 00 00 00 00 00 00 00 00 │
	; E0 │ 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 │
	; F0 │ 00 00 00 00 00 04 00 00 00 00 00 00 00 00 00 00 │ 
	;    └─────────────────────────────────────────────────┘
	;
	; Most amusingly, it looks like $4015 is read, but $4016 and $4017 aren't visible in this chart. (But don't let that fool you, as the controllers are still getting clocked... on some consoles.)
	
	; Re-enabled in the 2A07 form of test 5 (STA ($50),Y at $3FFE, no DMC DMA), with A = $02: the OAM DMA reads
	; page 2 while the 6502 address bus is at $4000. KEY: the published 2A03 table above, assumed unchanged on the
	; 2A07 (no 2A07 measurement exists). Pending hardware.
	JSR ClearPage2 ; This sets address $200 through $2FF to the value #$FF.
	LDX #$80
	LDA #0
TEST_APURegActivation_Prep6Loop: ; And this loop makes address $280 through $2FF the value #$00
	STA $200, X
	INX 
	BNE TEST_APURegActivation_Prep6Loop
	; As in test 5: eight passes, each with its own DMA and a 32-byte OAM read in the same VBlank.
	LDA #0
	STA <$5E
TEST_ARA7_Pass:
	LDA #$40
	STA $4017
	; Run the same setup as the above test.
	LDA #4
	STA $4015	; enable the triangle channel
	LDA #$F0
	STA $400B
	LDA #$FF
	STA $4008
	; strobe controllers.
	LDA #1
	STA $4016
	LSR A
	STA $4016
	; Put $50 in the PPU read buffer.
	JSR WaitForVBlank
	JSR DisableRendering
	LDA #0
	LDX #1
	STA $2002,X          ; OAMADDR = 0 (see test 5)
	JSR WriteToPPUADDRWithByte
	.byte $2C, $00
	.byte $50, $FF
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007 ; Prep the buffer with the value of $50 written to PPU $2C00
	JSR ResetScroll
	LDA #$14
	STA <$50
	LDA #$40
	STA <$51	; <$50/$51> = $4014
	; Put $91 in the PPU IO bus.
	LDA #$91
	STA $2002
	LDX #0
	LDA #$60
	STA <$01	; as in test 5: an ORA <$01,X instead of the BRK would at least find an RTS.
	LDY #0
	LDA #$02
	JSR $3FFE	; STA ($50),Y, then the OAM DMA of page 2 on the $4000 fetch, then BRK.
	;;;;;; A real big loop to read compare the values in OAM with the desired results.
	LDA <$5E
	ASL A
	ASL A
	ASL A
	ASL A
	ASL A
	JSR TEST_ARA_CopyOAM32
	INC <$5E
	LDA <$5E
	CMP #8
	BEQ TEST_ARA7_Done
	JMP TEST_ARA7_Pass
TEST_ARA7_Done:
	LDX #0
	
	LDY #$0B	; Y loops back to $00 in $15 bytes
TEST_APURegActivation_Eval_3:
	CPY #2
	BPL TEST_APURegActivation_Skip0601
	LDA $500,X						; Read the value copied from OAM at $2_5
	CMP #$24						; This should be 24
	BNE FAIL_APURegActivation2		; If it's not $24, you fail
	INX								; Increment X for the next one.
	LDA $500,X						; Read the value copied from OAM at $2_6
	CMP #$E3						; This should be E3
	BEQ TEST_APURegActivation_Eval_3p6; If it's not $E3, check $E0
	CMP #$E0
	BEQ TEST_APURegActivation_Eval_3p6; If it's not $E0, you fail
	CMP #$E1 						; And also check for $E1, which happens if you are holding A.
	BNE FAIL_APURegActivation2		; If it's not $E0, you fail
TEST_APURegActivation_Eval_3p6:
	INX								; Increment X for the next one.	
	LDA $500,X						; Read the value copied from OAM at $2_7
	CMP #$FF						; This should be FF
	BEQ TEST_APURegActivation_Eval_3p7; If it's not $FF, check $E0
	CMP #$E0						; This should be $FF (or $E0)
	BNE FAIL_APURegActivation2		; If it's not $FF, check $E0
	TEST_APURegActivation_Eval_3p7:
	INX								; Increment X for the next one.	
	LDY #03							; It probably should have been INY's for neatness, but this saves 2 CPU cycles.
TEST_APURegActivation_Skip0601:
	LDA $500,X						; Read the value copied from OAM
	PHA
	TXA
	AND #3
	CMP #02
	BNE TEST_APURegActivation_CheckForFFInsteadOfE7
	PLA
	CMP #$E3
	BNE FAIL_APURegActivation2
	BEQ TEST_APURegActivation_EvalCont
TEST_APURegActivation_CheckForFFInsteadOfE7:
	PLA
	CMP #$FF
	BNE FAIL_APURegActivation2		; If it's not $FF, you fail
TEST_APURegActivation_EvalCont:
	INY								; Increment Y for the next one.
	CPY #$20
	BNE TEST_APURegActivation_YSkip2	; if Y=20, reset to 0, so we can check for the "$04 $01"
	LDY #0
TEST_APURegActivation_YSkip2:
	INX								; Increment X for the next one.	
	CPX #$80
	BNE TEST_APURegActivation_Eval_3
TEST_APURegActivation_Eval_4:
	CPY #2
	BPL TEST_APURegActivation_Skip0602
	LDA $500,X						; Read the value copied from OAM at $2_5
	CMP #$04						; This should be 04
	BNE FAIL_APURegActivation2		; If it's not $04, you fail
	INX								; Increment X for the next one.
	LDA $500,X						; Read the value copied from OAM at $2_6
	BNE FAIL_APURegActivation2		; If it's not $00, you fail
	INX								; Increment X for the next one.	
	LDA $500,X						; Read the value copied from OAM at $2_7
	BNE FAIL_APURegActivation2		; If it's not $00, you fail
	INX								; Increment X for the next one.	
	LDY #03							; It probably should have been INY's for neatness, but this saves 2 CPU cycles.
TEST_APURegActivation_Skip0602:
	LDA $200,X						; Read the value copied from OAM
	BNE FAIL_APURegActivation2; If it's not $00, you fail
	INY								; Increment Y for the next one.
	CPY #$20
	BNE TEST_APURegActivation_YSkip3	; if Y=20, reset to 0, so we can check for the "$04 $01"
	LDY #0
TEST_APURegActivation_YSkip3:
	INX								; Increment X for the next one.	
	BNE TEST_APURegActivation_Eval_4
	INC <ErrorCode
	
	JMP TEST_APURegActivation_Finale ; I moved this part because it contains a lot of bytes, and ruined a bunch of branches.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

FAIL_APURegActivation2:
	LDA #$40
	STA $4017
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

FAIL_DMA_Timing:
	LDA #$40
	STA $4017
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_DMA_Plus_4015R:
	;;; Test 1 [DMA + $4015 Read]: Does the frame interrupt flag ever get set? ;;;
	SEI
	LDA #$00
	STA $4017
	JSR ClockslideFromWord
	.word PAL_APU_FRAME_IRQ_CYCLES ; PAL 2A07 frame IRQ: 33254
	BIT $4015	; If the frame interrupt flag is set, bit 6 will be set. (set the overflow flag)
	BVC FAIL_DMA_Timing
	INC <ErrorCode

	;;; Test 2 [DMA + $4015 Read]: Does the DMA happen at the right time? ;;;
	JSR DMASync_50CyclesRemaining
	LDA #$4F			;2
	STA $4010			;4
	LDA #$00			;2
	STA $4017			;4
	JSR Clockslide_PALFrame;33248
	JSR Clockslide_200	;100

	; so far, we've ran 29892 cycles since leaving our "DMA Sync in 50 CPU cycles." subroutine.
	; Luckily, I set the DMA to loop every 400 CPU cycles (rate $F on the 2A07).
	JSR Clockslide_16
	BIT $4015	; If the frame interrupt flag is set, bit 6 will be set (the overflow flag is set). The DMA is timed to land on this
			; instruction. On a 2A03 the DMA would also read $4015 and clear the flag first; a 2A07 DMA makes no extra read of
			; the halted CPU's address (it only halts on an opcode fetch), so the flag is still set here: V must be set.
	BVC FAIL_DMA_Timing ; 2A07: no extra $4015 read by the DMA, so V is set (see above)	
	
	;; END OF TEST ;;
	LDA #$40
	STA $4017
	LDA #1
	RTS
;;;;;;;

TEST_DMA_Plus_4016R:
	;;; Test 1 [DMA + $4016 Read]: Does the DMA Update the read-sensitive controller port? (also doubles as a test for DMA timing) ;;;
	
	JSR DMASync_50CyclesRemaining
	JSR Clockslide_35
	LDA #1		; -2 = 48
	STA $4016	; -4 = 44
	LDA #0		; -2 = 42
	STA $4016	; -4 = 38
	LDA $4016 	; -3 = 35
	LSR A
	ROL <$50
	LDX #7	; read from the controller port 7 more times.
TEST_DMA_Plus_4016R_Loop:
	LDA $4016
	LSR A
	ROL <$50
	DEX
	BNE TEST_DMA_Plus_4016R_Loop
	; read the controller again for a "control group" (the player might still be holding A, or for some other reason, other buttons.
	JSR ReadController1
	LDA <controller
	ASL A
	STA <$51
	LDA <$50
	CMP <$51
	BEQ TEST_DMA_Plus_4016R_SkipText1 ; Equal to a normal read = the DMA did not clock the controller an extra time.
	; That is the 2A07 result: its DMA only halts the CPU on an opcode fetch (NESdev forum "PAL DMA behavior", t=25939),
	; so it cannot land on the $4016 read above. (An older comment here said "PAL controller ports read all zero here";
	; no source supports that.) The reads are 16 cycles apart, more than the 5-7 cycles PAL consoles with controller-port
	; diodes need between reads (NESdev forum "Fast polling controllers on PAL", t=25279).
	LDA <$51
	ORA #1
	CMP <$50
	BNE DMA_Plus_4016R_TryFamicomControllerBehavior

	;; END OF TEST ;;
	LDA <RunningAllTests
	BNE TEST_DMA_Plus_4016R_SkipText1
	JSR WaitForVBlank
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $2370
	.byte "  $4016 Double-Read like NES  ", $FF
	JSR ResetScroll
TEST_DMA_Plus_4016R_SkipText1:
	LDA #5 ; Success code 1. NES / AV Famicom.
	RTS
	
DMA_Plus_4016R_TryFamicomControllerBehavior:
	LDA <$51
	ORA #7
	CMP <$50
	BNE FAIL_DMA_Plus_4016R
	;; END OF TEST ;;
	LDA <RunningAllTests
	BNE TEST_DMA_Plus_4016R_SkipText2
	JSR WaitForVBlank
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $2370
	.byte "$4016 Double-Read like Famicom", $FF
	JSR ResetScroll
TEST_DMA_Plus_4016R_SkipText2:
	LDA #9 ; Success code 2. Famicom.
	RTS
;;;;;;;
	FAIL_DMA_Plus_4016R:
	JMP TEST_Fail


	;;;;;;;;;;;;;;;;;;;;;;;;;
	;;; DMC Reload Timing ;;;
	;;;;;;;;;;;;;;;;;;;;;;;;;
TEST_DMCReloadTiming:
	LDX #0
	STX <$5D
	; STATUS: 2A07 form. The two LDA $4000 reads of the 2A03 form are replaced by the open-bus OPCODE probe (TEST_OBProbe_Install)
	; on the same cycles; waits derived from the PAL rate table (rate $F 50, $0 398 CPU cycles per bit; blargg t=1468). The
	; answer key is the original one re-encoded ($00 -> 1 = DMA seen, $40 -> 0); that the 2A07's reload timing matches it is
	; DERIVED (the reload is APU logic, which the 2A07 does not change as far as is known), not measured on PAL hardware.
	;;; Test 1 [DMC Reload Timing]: Do precisely timed writes to $4010 update the reload-value of the DMC timer correctly? ;;;
	; Basically we have a loop here that reads from open bus at two precise moments.
	; - read 1 would overlap with a DMC DMA if the write to $4010 does not update the reload-value.
	; - read 2 would overlap with a DMC DMA if the write to $4010 does update the reload-value.
	;
	; A refresher on the DMC timer:
	; - Writing to $4010 determines the sample rate.
	; - The timer is reloaded with a specific value, and counts down to zero. (Well- actually it's an LFSR, but it's way easier to visualize/emulate it as a counter counting down to zero.)
	; - When it hits zero, it is reloaded with the value again.
	; - It does this eight times, triggering a DMC DMA when it hits zero for the eighth time.
	; 	- In other words, the RDY pin of the CPU is set on the cycle after this timer/LFSR is reloaded for the 8th time, indicating that all the bits of the shift register have been used.
	;	- This timing was verified using visual 2A03, which until recently was speculated that there could be a delay between the timer expiring and the DMA occurring. But nope!
	;
	; In this loop, for every iteration, increment X.
	; We delay by X CPU cycles relative to the moment the DMC timer reloads, but sync everything back up relative to when the DMA will occur.
	; We write to $4010, changing the DMC sample rate. This write will occur around the moment the DMC timer needs to reload.
	; - The question this test aims to answer is, will it reload with the old value, or the new value?
	; We read from open bus at two precise moments in time. First, when the DMC DMA would have occurred with the fast sample rate, then the second read is with the slow sample rate.
	; These reads get recorded in RAM, and we compare with an answer key that was determined by running this on real hardware.

TEST_DMCReloadTimingLoop:            ;
	LDA #LOW(TEST_DMCReloadTiming_RetA) ; The open-bus opcode probe replaces the two LDA $4000 (see below)
	LDX #HIGH(TEST_DMCReloadTiming_RetA)
	JSR TEST_OBProbe_Install
	LDX <$5D                         ; the loop counter (X is needed for the install)
	JSR DMASync_50CyclesRemaining    ;
	; Using the fastest DMC Sample rate.
	; This means every reload should load the timer with 25 APU cycles remaining (50 CPU cycles on the 2A07).
	LDA #$4F                         ;
	STA $4010                        ; Loop + fastest rate.
	JSR Clockslide_44                ;
	; DMC DMA goes here.
	JSR ClockslideFromWord           ; Timing stuff.
	.word 298                        ; The write must land on the timer reload that starts the 8th bit after the
	; synced DMA: 7 bits of 50 CPU cycles (rate $F on the 2A07, NESdev "APU DMC" PAL table) = 350 after it, 28 sooner
	; than this wait was built for (7 * 54): 326 - 28 = 298.
	TXA                              ; Timing stuff.
	JSR Clockslide37_Plus_A          ; Timing stuff.
	LDA #$40                         ; Timing stuff.
	                                 ;
	                                 ; Honestly, don't worry too much about the timing stuff.
	                                 ; The important thing is that we write to STA $4010 right before the DMC timer reloads.
	                                 ; This happens in a loop, and the loop runs 6 times with different timing each timer. Here's how each 6 iterations of the loop work out:
	                                 ; 0: The write to $4010 occurs 3 CPU cycles before the timer reloads. : The timer is reloaded with 398 CPU cycles.
	                                 ; 1: The write to $4010 occurs 2 CPU cycles before the timer reloads. : The timer is reloaded with 398 CPU cycles.
	                                 ; 2: The write to $4010 occurs 1 CPU cycle before the timer reloads.  : The timer is reloaded with 398 CPU cycles.
	                                 ; 3: The write to $4010 occurs on the same cycle the timer reloads.   : The timer is reloaded with 398 CPU cycles.
	                                 ; 4: The write to $4010 occurs 1 CPU cycle after the timer reloads.   : The timer is reloaded with 50 CPU cycles.
	                                 ; 5: The write to $4010 occurs 2 CPU cycles after the timer reloads.  : The timer is reloaded with 50 CPU cycles.
	                                 ;
	STA $4010                        ; !!! Write to address $4010 to change the sample rate. This write will be occurring around the same time the DMC timer needs to reload.
	                                 ; If the write to $4010 happens before the DMC timer reloads, the DMC timer will be reloaded with the slowest sample rate.
	                                 ; If the write to $4010 happens after the DMC timer reloads... well, the timer already reloaded so it still had the fastest sample rate.
	                                 ; Amusingly, this test also confirms that if the write to $4010 happens on the same cycle as the timer reloading, then the sample rate changes, and the DMC timer takes the new value.\
	                                 ; Now all we need to do is confirm if the DMC timer was reloaded with the fastest sample rate or the slowest sample rate.
	                                 ; This can be done with two precisely timed reads from open bus. One when the DMC DMA would occur with the faster rate, and one when it would occur with the slower rate.
	                                 ; And then we can just compare with the results that were recorded on consoles.
	TXA                              ; Timing stuff.
	TAY                              ; Timing stuff.
	DEY                              ; Timing stuff.
	.byte $30, $00                   ; Timing stuff. 3 cycles if Y is negative, 2 if positive.
	DEY                              ; Timing stuff.
	.byte $30, $00                   ; Timing stuff. 3 cycles if Y is negative, 2 if positive.
	DEY                              ; Timing stuff.
	.byte $30, $00                   ; Timing stuff. 3 cycles if Y is negative, 2 if positive.
	DEY                              ; Timing stuff.
	.byte $30, $00                   ; Timing stuff. 3 cycles if Y is negative, 2 if positive.
	DEY                              ; Timing stuff.
	.byte $30, $00                   ; Timing stuff. 3 cycles if Y is negative, 2 if positive.
	DEY                              ; Timing stuff.
	.byte $30, $00                   ; Timing stuff. 3 cycles if Y is negative, 2 if positive.
	                                 ; Timing stuff. in total, 32 cycles, and we balance out the +A from earlier.
	; 2A07 form. The two LDA $4000 reads saw the DMA through open bus; on a 2A07 a DMA only lands on an opcode fetch
	; (NESdev forum "PAL DMA behavior", RP2A07 traces), so each read is replaced by the open-bus opcode probe
	; (TEST_OBProbe_Install), with its $4000 fetch on the cycle the 2A03 form's LDA reads: 19 cycles after the DEY chain
	; for the first (that form's TXA/ASL/TAY 6 + 5 NOPs 10 + 3), 348 cycles later for the second. Results are 1 (DMA
	; landed) or 0, stored at $500,Y / $501,Y; the key is the 2A03 form's with $00 -> 1 and $40 -> 0.
	BIT <$00                         ; 3
	LDA #HIGH(TEST_DMCReloadTiming_RetA) ; 2
	PHA                              ; 3
	LDA #LOW(TEST_DMCReloadTiming_RetA) ; 2
	PHA                              ; 3
	PHP                              ; 3
	JMP $4000                        ; 3: $4000 fetch 19 cycles after the DEY chain = the fast-rate DMA's request
TEST_DMCReloadTiming_RetA:           ; without a DMA: 6 cycles (RTI) after that fetch
	TXA                              ; 2
	ASL A                            ; 2
	TAY                              ; 2
	LDA <$50                         ; 3
	STA $500, Y                      ; 5
	LDA #0                           ; 2
	STA <$50                         ; 3
	LDA #LOW(TEST_DMCReloadTiming_RetB) ; 2
	STA <$5E                         ; 3
	LDA #HIGH(TEST_DMCReloadTiming_RetB) ; 2
	STA <$5F                         ; 3   -> 35 after the first $4000 fetch
	JSR ClockslideFromWord           ; 348 - 35 - 16 = 297
	.word 297
	LDA #HIGH(TEST_DMCReloadTiming_RetB) ; 2
	PHA                              ; 3
	LDA #LOW(TEST_DMCReloadTiming_RetB) ; 2
	PHA                              ; 3
	PHP                              ; 3
	JMP $4000                        ; 3: $4000 fetch 348 after the first = the slow-rate DMA's request
TEST_DMCReloadTiming_RetB:
	LDA <$50
	STA $501, Y
	INX                              ; Let's run this in a loop, delaying by 1 additional cycle each loop before to write to $4010.
	STX <$5D
	CPX #6                           ; And we'll do this six times.
	BNE TEST_DMCReloadTimingLoop     ;
	                                 ;
	LDX #0                           ;
TEST_DMCReloadTiming_KeyLoop:        ; I had to move the answer key somewhere else in the ROM to fit it in. (I'm running out of bytes.)
	LDA $500, X                      ; The pattern should be "Early, Early, Early, Early, Late, Late"
	CMP TEST_DMCReloadTiming_Key, X  ; Which looks like "40 00" "40 00" "40 00" "40 00" "00 40" "00 40"
	BNE FAIL_DMCReloadTiming         ; Which suggests that writing to $4010 on the same APU cycle that the timer reloads does in-fact use the new value.
	INX                              ;
	CPX #12                          ;
	BNE TEST_DMCReloadTiming_KeyLoop ;
	                                 ;
	;; End of Test ;;                ;
	LDA #1                           ;
	RTS                              ;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	
FAIL_DMCReloadTiming:
	JMP TEST_Fail
	
TEST_DMCReloadTiming_Key:            ; Probe results: 1 = the DMA landed on that probe (the 2A03 key's $00), 0 = it did not ($40)
	.byte 0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0
	
;;;;;;;
	; [Sprites On Scanline 0] is placed here, in free space before bank 2.
TEST_Scanline0Sprites_TimeItRight:
	; PAL form. The 2C02 version turns rendering off for almost a frame and keeps OAM alive with 56 back-to-back OAM
	; DMAs, then enables rendering just after dot 66 of the pre-render line. On a 2C07, DMAs during the forced OAM
	; refresh (scanlines 265-310) land at a moving OAMADDR and scramble OAM, so this version syncs to VBlank, runs one
	; OAM DMA early in VBlank (OAMADDR = 0 first, before the refresh starts), and waits for the pre-render line (311).
	; The enable write lands on dots 99-102 of scanline 311 (2C02 version: dots 90-114 of scanline 261),
	; and the $2002 read 474 dots later, as there.
	; Secondary OAM has to hold sprite zero when rendering is turned off. Sprite zero is at Y = 50 (see test 2), so it
	; is in range on scanlines 50-57: wait 50 scanlines (5328 CPU cycles) from dot ~300 of scanline 0, so rendering is
	; turned off after scanline 50's evaluation, as the 2C02 version turns it off after scanline 0's.
	JSR ClockslideFromWord
	.word 5328
	LDA #0
	STA $3E01 ; disable rendering.
	LDA #0
	JSR VblSync_Plus_A ; rendering is off: sync to the start of VBlank.
	LDA #0
	STA $2003
	LDA #$2
	STA $4014 ; one OAM DMA, early in VBlank.
	JSR ClockslideFromWord
	.word 6935
	LDA #$1E
	STA $2001 ; Enable rendering briefly after dot 66 on the pre-render line.
	; wait until HBlank after scanline 0: 148 CPU cycles (474 dots, as the 2C02 version's 158 cycles)
	JSR Clockslide_100
	JSR Clockslide_42
	LDX <$50 ; This is for storing the test results at address $50x after the RTS
	LDA $2002 ; Read PPUSTATUS checking for sprite zero hit.
	AND #$40 ; bitwise AND to just keep bit 6.
	RTS
;;;;;;;

TEST_Scanline0Sprites:
	;;; Test 1 [Sprites On Scanline 0]: Sprites at Y=0 aren't actually drawn at Y=0. ;;;
	; This is just a test to weed out false positives.
	
	JSR DisableRendering
	LDA #0
	TAX
TEST_Scanline0Sprites_ClearPg2: ; clear page 2 (used for OAM DMA) with all zeroes!!!
	STA $200, X
	INX
	BNE TEST_Scanline0Sprites_ClearPg2

	JSR SetUpSpriteZero ; And set up sprite zero in this way.
	.byte $00, $C6, $00, $80
	; CHR $C6 is a single pixel on row 5:
	;
	; . . . . . . . .
	; . . . . . . . .
	; . . . . . . . .
	; . . . . . . . .
	; . . . . . . . .
	; # . . . . . . .
	; . . . . . . . .
	; . . . . . . . .

	JSR PrintCHR
	.word $2000
	.byte $24, $FF ; Draw tile $24 at $2000 (empty square)
	JSR PrintCHR
	.word $2010
	.byte $C0, $FF ; Draw tile C0 at $2010 (a single pixel)
	
	JSR ResetScroll
		
	JSR WaitForVBlank ; Wait for vblank
	JSR EnableRendering
	JSR OAMDMAWithPage2
	JSR WaitForVBLSpriteZeroHit; Wait for vblank and load A with $2002.6
	BEQ P3ne0Sprites_1
FAIL_Scanline0Sprites1_N7:
	JMP FAIL_Scanline0Sprites1
P3ne0Sprites_1:
	INC <ErrorCode
	
	;;; Test 2 [Sprites On Scanline 0]: Under specific circumstances, a sprite can be drawn on scanline 0 ;;;
	; Well, as it turns out, sprites *can* be drawn on scanline 0.
	; See https://forums.nesdev.org/viewtopic.php?t=26291
	
	; In summary, OAM data can be drawn on scanline 0, since the pre-render line is treated as scanline 5 for the in-range checks occurring during dots 256 to 319
	; (evaluated as line (261 & 255) = scanline 5. That's also why CHR $C6 (the character used for sprite zero during this test) has a single pixel on row 5.)
	; This results in the existing data in secondary OAM being put into the sprite shifters on the pre-render line. (only if the sprite is "in-range" of scanline 5.)
	; The data in secondary OAM would either exist due to the previous frame's scanline 239, or whatever was in secondary OAM before rendering was disabled. (F-Blank)

	LDA #$4C ; Set up NMI routine, since I'm using the NMI to sync the CPU and PPU.
	STA $700
	LDA #Low(RunScanline0Sprite_NMI)
	STA $701
	LDA #HIGH(RunScanline0Sprite_NMI)
	STA $702

	; This subroutine will basically verify that a sprite zero hit is occurring on scanline 0.

	; PAL: the 2C07's pre-render line is 311, so its in-range check uses (311 & 255) = 55, not 5. Sprite zero is moved
	; to Y = 50 ($32), so the same row 5 of CHR $C6 is the row drawn on scanline 0. (Derived from the 2C02 behavior
	; described above; pending hardware.)
	LDA #$32
	STA $200
	JSR RunScanline0SpriteTest ; The test occurs in this subroutine. I use a subroutine so I can change very few things and run the same code again.
	
	LDA #2
	STA <$50 ; this is used to keep these test results in a different address than the previous two results.
	JSR DisableRendering

	JSR PrintCHR
	.word $2010
	.byte $24, $FF ; Draw tile $24 at $2010 (empty square)
	JSR PrintCHR
	.word $2000
	.byte $C0, $FF ; Draw tile C0 at $2000 (a single pixel)

	JSR ResetScroll
	JSR Clockslide_PALFrame ; one PAL frame

	; The pre-render line skips the last dot, resulting in an interesting side effect.
	; The first pixel of the sprite shift registers gets drawn at x=0 instead of the intended x position. 
	; The 7 remaining pixels are drawn as normal, but shifted left by 1 pixel.
	;
	; Basically, this will cause an alternating pattern, where on one frame the sprite on scanline 0 will be shifted at x=0, and on the next frame it will not.
	; I'm going to verify this behavior by checking if the sprite zero hit alternates each frame.
	;
	; Let's run this test again for sprite zero hits at X=0 now.

	JSR RunScanline0SpriteTest ; The test occurs in this subroutine again. (The nametable was modified.)

	JSR WaitForVBlank

	JSR PrintCHR
	.word $2000
	.byte $24, $FF
	JSR ResetScroll
	JSR DisableRendering_S

	; And now we evaluate the results!!!
	; $500 and $501 are the first test results, where we're looking for a sprite zero hit where X=$80
	; $502 and $503 are the second test results, where we're looking for a sprite zero hit where X=$00
	; On an RP2C02, there should be one passing test from each set, and one failing test from each set. (50% chance split for which one passes.)
	; On an RP2C03, there should be two passing from the first set, and two failing from the second set.

	LDA $500
	ORA $501
	BNE P3ne0Sprites_2
FAIL_Scanline0Sprites_N8:
	JMP FAIL_Scanline0Sprites
P3ne0Sprites_2:
	INC <ErrorCode
	
	;;; Test 3 [Sprites On Scanline 0]: (2C07) Both frames give the same result, and no sprite zero hit occurs at X=0. ;;;
	; The 2C02 version tells a composite 2C02 (it skips one dot on alternate frames, so the two frames differ and one
	; of them hits at X=0) from an RGB 2C03 (no skipped dot: both frames the same, no hit at X=0). The 2C07 never skips
	; a dot (PAL frames are always 312 x 341 dots; NESdev "PPU frame timing"), so its results must be the RGB ones.
	LDA $500
	CMP $501
	BEQ TEST_Scanline0Sprites_SameFrames
	JMP FAIL_Scanline0Sprites ; the two frames differ, as only a PPU that skips a dot would make them
TEST_Scanline0Sprites_SameFrames:
	LDA $502
	ORA $503
	BEQ TEST_Scanline0Sprites_NoHitAtX0
	JMP FAIL_Scanline0Sprites ; a sprite zero hit at X=0
TEST_Scanline0Sprites_NoHitAtX0:
	;; END OF TEST ;;
	LDA #1
	RTS
FAIL_Scanline0Sprites:
	JMP TEST_Fail
;;;;;;;

RunScanline0SpriteTest:
	LDA #$80
	STA $2000 ; enable NMI
RunScanline0Sprite_WaitForNMI:
	JMP RunScanline0Sprite_WaitForNMI ; wait for NMI to sync CPU and PPU
	
RunScanline0Sprite_NMI:
	PLA ; remove the NMI's return status and address.
	PLA ; ^
	PLA ; ^
	LDA #0
	STA $2000 ; Disable NMI		
	STA $2003 ; Set OAM Address to $00 just to be safe.
	LDA #$1E  
	STA $2001 ; Enable rendering
	LDA #2
	STA $4014 ; OAM DMA with page 2.
	JSR ClockslideFromWord ; PAL: TEST_Scanline0Sprites_TimeItRight is entered on dot ~300 of scanline 0, the same point
	.word 7091             ; as its second call (2C02 version: 1918 of a 2273-cycle VBlank; PAL VBlank is 7459 cycles).
	
	JSR TEST_Scanline0Sprites_TimeItRight ; Time it right to toggle rendering a bunch such that sprite zero appears on scanline 0.
	STA $500, X	
	; And do it again on the following frame so we can collect the data for consecutive frames.
	JSR TEST_Scanline0Sprites_TimeItRight ; Time it right to toggle rendering a bunch such that sprite zero appears on scanline 0.
	STA $501, X
	RTS
;;;;;;;
;;;;;;;
T24_Run:
	; 44 passes, each 1.6 dots later than the one before; 5 reads per pass, 22 CPU cycles (70.4 dots) apart, starting on
	; scanline $80. Read r of pass p is stored at $500 + 44r + p (in increasing dot order).
	; One sync, then every pass takes exactly 33248 CPU cycles: half a cycle (1.6 dots) more than a PAL frame. (The OAM
	; DMA comes before the sync: a DMA takes 513 or 514 cycles depending on the cycle parity.)
	LDA #0
	STA $2003
	LDA #2
	STA $4014
	LDA #0
	STA <$5E ; pass
	JSR VblSync_Plus_A
	LDA #$18
	STA $2001
T24_Pass:
	LDY <$5E    ; +3
	LDX #5      ; +2
	JSR ClockslideFromWord
	.word 21174 ; the first read of pass 0 lands on scanline $80, dot ~0
T24_Read:
	LDA $2004   ; +4
	STA $500,Y  ; +5
	TYA         ; +2
	CLC         ; +2
	ADC #44     ; +2
	TAY         ; +2
	DEX         ; +2
	BNE T24_Read ; +3: 22 CPU cycles per read (109 for the 5)
	INC <$5E    ; +5
	LDA <$5E    ; +3
	CMP #44     ; +2
	BEQ T24_RunDone ; +2
	JSR ClockslideFromWord
	.word 11945 ; 33248 - 21174 - 129: the next pass starts 33248 cycles after this one
	JMP T24_Pass ; +3
T24_RunDone:
	JSR DisableRendering
	RTS
;;;;;;;
KEYDATA_2:
	.byte $3B, $7E, $7E, $02, $02, $40, $40, $DD, $DD, $7D, $7D, $03, $03, $60, $60, $CC
	.byte $CC, $7C, $7C, $04, $04, $80, $80, $BB, $BB, $7B, $7B, $05, $05, $A0, $A0, $AA
	.byte $AA, $7A, $7A, $06, $06, $C0, $C0, $99, $99, $79, $79, $07, $07, $E0, $E0, $88
	.byte $88, $00, $80, $05, $80, $02, $80, $0F, $80, $10, $80, $15
	.byte $83, $08
	.byte $0C, $1F, $80, $20, $80, $25, $80, $22, $80, $2F, $80, $30, $80
	.byte $80, LOW(KEYDATA_3), HIGH(KEYDATA_3) ; continued
	.bank 2	; If I don't do this, the ROM won't compile.
	.org $C000
	; and 33 00s in a row for a nice and neat silent DPCM sample.
	; (Split in three lines: this assembler truncates a long .byte line without an error, which left only 24 of the
	; 33 bytes before.)
	.byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
	.byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
	.byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00

FAIL_ControllerStrobing:
	JMP TEST_Fail
	
TEST_ControllerStrobing:
	;;; Test 1 [Controller Strobing] The controller is only strobed if the value written to $4016 has a 1 in bit 0.
	; This test only works if controller 1 is pressing either no buttons, or only A.
		
	LDA #2
	STA $4016	; does not strobe the controller.
	LDA #0
	STA $4016
	JSR ReadControllerInto50_and_A
	AND #$7F
	CMP #$7F
	BNE FAIL_ControllerStrobing
	INC <ErrorCode
	
	;;; Test 2 [Controller Strobing] The controller is only strobed if the value written to $4016 has a 1 in bit 0. (continued)
	LDA #3
	STA $4016 ; does strobe the controller.
	LDA #0
	STA $4016
	JSR ReadControllerInto50_and_A
	AND #$7F
	BNE FAIL_ControllerStrobing	; the result should be $00
	INC <ErrorCode

	;;; Test 3 [Controller Strobing]: Do controller strobes only happen when the CPU transitions from a get cycle to a put cycle? ;;;
	; This test will run DEC $4016
	; cycle 1: read the opcode
	; cycle 2: read the operand (low byte)
	; cycle 3: read the operand (high byte)
	; cycle 4: read from address $4016 ($41)
	; cycle 5: write ($41) to $4016, then DEC to ($40)
	; cycle 6: write ($40) to $4016
	;
	; This results in a 1-cycle strobe of the controller ports!
	; - if that 1-cycle strobe happens on a get cycle, the controllers actually aren't strobed at all! (See the next error code)
	; - But if the strobe occurs on a put cycle, the controllers DO get strobed.
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync CPU with "get" cycle.
	DEC $4016 ; (get) (put) (get) (put) (get) [PUT] [GET] : this should strobe the controller.
	JSR ReadControllerInto50_and_A
	AND #$7F
	BNE FAIL_ControllerStrobing	; the result should be $00
	INC <ErrorCode

	;;; Test 4 [Controller Strobing]: Do controller strobes only happen when the CPU transitions from a get cycle to a put cycle? (continued) ;;;
	; This results in a 1-cycle strobe of the controller ports, however they actually aren't strobed at all!
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync CPU with "get" cycle.
	LDA <$00  ; (get) (put) (get) 3 CPU cycles.
	DEC $4016 ; (put) (get) (put) (get) (put) [GET] [PUT] this should not strobe the controller.
	JSR ReadControllerInto50_and_A
	CMP #$FF
	BNE FAIL_ControllerStrobing	; the result should be $FF
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

TEST_InstructionTiming_Looped_FFs:
	STA <$50 ; Store the opcode of the test in RAM.
	TXA 
	PHA ; Push X to the stack.
	LDX #$FF ; Set X to $FF. This is used for indexed absolute addressing that needs to cross a page boundary.
	LDY #$FF ; Set Y to $FF. This is used for indexed absolute addressing that needs to cross a page boundary.
	JMP TEST_InstructionTiming_Looped_Start ; Skip ahead.

TEST_InstructionTiming_Looped: ; For the tests that run in loops, just jump to this subroutine.
	STA <$50 ; Store the opcode of the test in RAM.
	TXA  
	PHA ; Push X to the stack.
	LDX #0 ; Reset X.
	LDY #0 ; Reset Y.
TEST_InstructionTiming_Looped_Start:;
	JSR CycleClockBegin ; Starts the clock.
	JSR $0050 ; This takes 12 cycles + the cycles of the instruction being tested.
	JSR CycleClockEnd ; Stop the clock, and put the total counted CPU cycles in the Y register.
	PLA ; Pull the old X register off the stack.
	TAX ; Restore X.
	STY $500 ; Store the value of the Y register (the number of cycles we counted) at address $500 for easy debugging.
	RTS
;;;;;;;


FAIL_InstructionTiming:
	JMP TEST_Fail

TEST_InstructionTiming:
	; STATUS: measured with the 2A07 cycle clock (frame IRQ, CycleClock2_Begin); no open bus anywhere. The clock is
	; calibrated on an empty interval and checked on two NOPs (CheckDMATiming). Keys are instruction cycle counts, except
	; the BRK subtest, whose key adds the clock's own 40-cycle handler path (counted from the code). Not yet run on PAL hardware.
	;;; Test 1 [Instruction Timing]: Can the DMA sync be done at all? ;;;
	; 2A07 form: can we sync to the DMA at all? On a 2A07 the sync executes an opcode from open bus
	; (DMASyncWithoutOpenBus), and the cycle clock is built on the same probe (CycleClock2_Begin), so test 2 does not
	; need the open-bus data read the pre-test checks for.
	JSR DMASync
	LDA $07EA
	BNE FAIL_InstructionTiming
	INC <ErrorCode
	
	;;; Test 2 [Instruction Timing]: Is the cycle clock right on a known interval (two NOPs = 4 cycles)? ;;;
	JSR CheckDMATiming
	CPY #4 ; 
	BNE FAIL_InstructionTiming
	; To be honest, in order to make it this far, you're going to need some very accurate DMA timing, and I guess also "NOP" needs to be 2 cycles, for that matter.
	
	; Now we can see how long various instructions take.
	LDA #$60 ; RTS
	STA <$50
	STA <$51
	STA <$52 
	STA <$53 

	JSR CycleClockBegin
	JSR $0050 ; this takes 12 cycles
	JSR CycleClockEnd
	CPY #12
	BNE FAIL_InstructionTiming
	; If JSR + RTS does not equal 12 cycles, then we have a problem.
	; otherwise...
	INC <ErrorCode

	;;; Test 3 [Instruction Timing]: The immediate addressing mode takes 2 cycles ;;;
	; If you fail this test, press select to view the debug menu.
	; The value at address $50 (the bottom left of the upper block) will be the opcode tested which failed.
	
	LDX #0	
TEST_InstructionTiming_Loop_Imm:
	LDA TEST_InstructionTiming_Immediates, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+2 ; So let's see if this took 2 cycles.
	BNE FAIL_InstructionTiming
	INX
	CPX #11
	BNE TEST_InstructionTiming_Loop_Imm
	INC <ErrorCode
	
	;;; Test 4 [Instruction Timing]: The Zero Page addressing mode for non-Read-Modify-Write instructions take 3 cycles ;;;
	LDX #0
TEST_InstructionTiming_Loop_ZP:
	LDA TEST_InstructionTiming_ZPs, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+3 ; So let's see if this took 3 cycles.
	BNE FAIL_InstructionTiming2
	INX
	CPX #10
	BNE TEST_InstructionTiming_Loop_ZP
	INC <ErrorCode
	
	;;; Test 5 [Instruction Timing]: The Zero Page addressing mode for Read-Modify-Write instructions take 5 cycles ;;;
	LDX #0
TEST_InstructionTiming_Loop_ZP2:
	LDA TEST_InstructionTiming_ZP2s, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+5 ; So let's see if this took 5 cycles.
	BNE FAIL_InstructionTiming2
	INX
	CPX #6
	BNE TEST_InstructionTiming_Loop_ZP2
	INC <ErrorCode

	;;; Test 6 [Instruction Timing]: The Indexed Zero Page addressing mode for non-Read-Modify-Write instructions take 4 cycles ;;;
	LDX #0
TEST_InstructionTiming_Loop_iZP:
	LDA TEST_InstructionTiming_iZPs, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+4 ; So let's see if this took 4 cycles.
	BNE FAIL_InstructionTiming2
	INX
	CPX #10
	BNE TEST_InstructionTiming_Loop_iZP
	INC <ErrorCode

	;;; Test 7 [Instruction Timing]: The Indexed Zero Page addressing mode for Read-Modify-Write instructions take 6 cycles ;;;
	LDX #0
TEST_InstructionTiming_Loop_i2ZP:
	LDA TEST_InstructionTiming_iZP2s, X
	JSR TEST_InstructionTiming_Looped ; run the test
	STY $500  ; for easy debugging.
	CPY #12+6 ; So let's see if this took 6 cycles.
	BNE FAIL_InstructionTiming2
	INX
	CPX #6
	BNE TEST_InstructionTiming_Loop_i2ZP
	INC <ErrorCode
		BNE FAIL_InstructionTiming_Continue
FAIL_InstructionTiming2:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;
FAIL_InstructionTiming_Continue:
	;;; Test 8 [Instruction Timing]: The Absolute addressing mode for non-Read-Modify-Write instructions take 4 cycles ;;;
	LDX #0
TEST_InstructionTiming_Loop_A:
	LDA TEST_InstructionTiming_As, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+4 ; So let's see if this took 4 cycles.
	BNE FAIL_InstructionTiming2
	INX
	CPX #15
	BNE TEST_InstructionTiming_Loop_A
	INC <ErrorCode

	;;; Test 9 [Instruction Timing]: The Absolute addressing mode for Read-Modify-Write instructions take 6 cycles ;;;
	LDX #0
TEST_InstructionTiming_Loop_A2:
	LDA TEST_InstructionTiming_A2s, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+6 ; So let's see if this took 4 cycles.
	BNE FAIL_InstructionTiming2
	INX
	CPX #6
	BNE TEST_InstructionTiming_Loop_A2
	INC <ErrorCode
	
	;;; Test A [Instruction Timing]: The indexed Absolute addressing mode for STA instructions always take 5 cycles ;;;
	LDX #0
TEST_InstructionTiming_Loop_iA:
	LDA TEST_InstructionTiming_iAs, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+5 ; So let's see if this took 5 cycles.
	BNE FAIL_InstructionTiming2
	INX
	CPX #2
	BNE TEST_InstructionTiming_Loop_iA
	
	LDX #0
TEST_InstructionTiming_Loop_iA_2:
	LDA TEST_InstructionTiming_iAs, X
	JSR TEST_InstructionTiming_Looped_FFs ; run the test with the X and Y registers set to $FF
	CPY #12+5 ; So let's see if this took 5 cycles.
	BNE FAIL_InstructionTiming3
	INX
	CPX #2
	BNE TEST_InstructionTiming_Loop_iA_2
	INC <ErrorCode
	
	;;; Test B [Instruction Timing]: The indexed Absolute addressing mode for many instructions take an extra cycle if the page boundary was crossed. ;;;
	LDX #0
TEST_InstructionTiming_Loop_iAp:
	LDA TEST_InstructionTiming_iAs_plus, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+4 ; So let's see if this took 4 cycles.
	BNE FAIL_InstructionTiming3
	INX
	CPX #16
	BNE TEST_InstructionTiming_Loop_iAp
	
	LDX #0
TEST_InstructionTiming_Loop_i2Ap:
	LDA TEST_InstructionTiming_iAs_plus, X
	JSR TEST_InstructionTiming_Looped_FFs ; run the test with the X and Y registers set to $FF
	CPY #12+5 ; So let's see if this took 5 cycles.
	BNE FAIL_InstructionTiming3
	INX
	CPX #16
	BNE TEST_InstructionTiming_Loop_i2Ap
	INC <ErrorCode
	BNE TEST_InstructionTiming_Cont2
FAIL_InstructionTiming3:
	JMP TEST_Fail
TEST_InstructionTiming_Cont2:

	;;; Test C [Instruction Timing]: The indexed Absolute addressing mode for Read-Modify-Write instructions always take 7 cycles ;;;
	LDX #0
TEST_InstructionTiming_Loop_RMWiA:
	LDA TEST_InstructionTiming_iA2s, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+7 ; So let's see if this took 7 cycles.
	BNE FAIL_InstructionTiming3
	INX
	CPX #6
	BNE TEST_InstructionTiming_Loop_RMWiA
	
	LDX #0
TEST_InstructionTiming_Loop_2RMWiA:
	LDA TEST_InstructionTiming_iA2s, X
	JSR TEST_InstructionTiming_Looped_FFs ; run the test with the X and Y registers set to $FF
	CPY #12+7 ; So let's see if this took 7 cycles.
	BNE FAIL_InstructionTiming3
	INX
	CPX #6
	BNE TEST_InstructionTiming_Loop_2RMWiA
	INC <ErrorCode

	;;; Test D [Instruction Timing]: The Indirect, X instructions always take 6 cycles (well, except for the unofficial ones) ;;;
	LDA #05
	STA <$61
	STA <$60
	LDX #0
TEST_InstructionTiming_Loop_indX:
	LDA TEST_InstructionTiming_inX, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+6 ; So let's see if this took 5 cycles.
	BNE FAIL_InstructionTiming3
	INX
	CPX #8
	BNE TEST_InstructionTiming_Loop_indX
	INC <ErrorCode
	
	;;; Test E [Instruction Timing]: The Indirect, Y instructions take an extra cycle if a page boundary is crossed.;;;
	LDX #0
TEST_InstructionTiming_Loop_Yind:
	LDA TEST_InstructionTiming_inY, X
	JSR TEST_InstructionTiming_Looped ; run the test
	CPY #12+5 ; So let's see if this took 5 cycles.
	BNE FAIL_InstructionTiming4
	INX
	CPX #7
	BNE TEST_InstructionTiming_Loop_Yind
	LDX #0
TEST_InstructionTiming_Loop_Y2ind:
	LDA TEST_InstructionTiming_inY, X
	JSR TEST_InstructionTiming_Looped_FFs ; run the test with the X and Y registers set to $FF
	CPY #12+6 ; So let's see if this took 6 cycles.
	BNE FAIL_InstructionTiming4
	INX
	CPX #7
	BNE TEST_InstructionTiming_Loop_Y2ind
	INC <ErrorCode

	LDA $4015
	LDA #$40
	STA $4017

	;;; Test F [Instruction Timing]: The Implied instructions take 2 cycles.;;;
	; Make sure interrupts cannot happen:
	LDA #$40
	STA $4017
	LDA $4015
	LDX #0
TEST_InstructionTiming_Loop_Implied:
	LDA TEST_InstructionTiming_Implied, X
	STA <$50
	TXA
	PHA
	TSX ; Transfer stack pointer to X, so when TXS runs, we don't break anything.
	DEX ; Oh wait- we'll need to account for the stack pointer moving from the JSR.
	DEX ; Okay, now we're all set.
	LDY #$FF
	JSR CycleClockBegin
	JSR $0050 ; this takes 12 cycles + the cycles of the instruction being tested.
	JSR CycleClockEnd
	PLA ; PLA before branching to a fail condition.
	TAX
	STY $500  ; for easy debugging.
	CPY #12+2 ; So let's see if this took 6 cycles.
	BNE FAIL_InstructionTiming4
	INX
	CPX #22
	BNE TEST_InstructionTiming_Loop_Implied
	CLD
	INC <ErrorCode
	BNE TEST_InstructionTiming_Cont3
FAIL_InstructionTiming4:
	JMP TEST_Fail
TEST_InstructionTiming_Cont3:
	; The rest of the tests are not in loops.
	;;; Test G [Instruction Timing]: PHP takes 3 cycles ;;;
	JSR CycleClockBegin
	PHP
	JSR CycleClockEnd
	PLA
	STY $500  ; for easy debugging.
	CPY #3
	BNE FAIL_InstructionTiming4
	INC <ErrorCode
	
	;;; Test H [Instruction Timing]: PHA takes 3 cycles ;;;
	JSR CycleClockBegin
	PHA
	JSR CycleClockEnd
	PLA
	STY $500  ; for easy debugging.
	CPY #3
	BNE FAIL_InstructionTiming4
	INC <ErrorCode
	
	;;; Test I [Instruction Timing]: PLP takes 4 cycles ;;;
	PHA
	JSR CycleClockBegin
	PLP
	JSR CycleClockEnd
	STY $500  ; for easy debugging.
	CPY #4
	BNE FAIL_InstructionTiming4
	INC <ErrorCode

	;;; Test J [Instruction Timing]: PLA takes 4 cycles ;;;
	PHA
	JSR CycleClockBegin
	PLA
	JSR CycleClockEnd
	STY $500  ; for easy debugging.
	CPY #4
	BNE FAIL_InstructionTiming4
	INC <ErrorCode
	
	;;; Test K [Instruction Timing]: JMP takes 3 cycles ;;;
	JSR CycleClockBegin
	JMP TEST_InstructionTiming_JMP
TEST_InstructionTiming_JMP:
	JSR CycleClockEnd
	STY $500  ; for easy debugging.
	CPY #3
	BNE FAIL_InstructionTiming4
	INC <ErrorCode
	
	;;; Test L [Instruction Timing]: JSR takes 6 cycles ;;;
	JSR CycleClockBegin
	JSR TEST_InstructionTiming_JSR
TEST_InstructionTiming_JSR:
	JSR CycleClockEnd
	PLA
	PLA
	STY $500  ; for easy debugging.
	CPY #6
	BNE FAIL_InstructionTiming4
	INC <ErrorCode

	;;; Test M [Instruction Timing]: RTS takes 6 cycles ;;;
	LDA #HIGH(TEST_InstructionTiming_RTS-1)
	PHA
	LDA #LOW(TEST_InstructionTiming_RTS-1)
	PHA
	JSR CycleClockBegin
	RTS
TEST_InstructionTiming_RTS:
	JSR CycleClockEnd
	STY $500  ; for easy debugging.
	CPY #6
	BNE FAIL_InstructionTiming5
	INC <ErrorCode
	
	;;; Test N [Instruction Timing]: RTI takes 6 cycles ;;;
	LDA #HIGH(TEST_InstructionTiming_RTI)
	PHA
	LDA #LOW(TEST_InstructionTiming_RTI)
	PHA
	PHA
	JSR CycleClockBegin
	RTI
TEST_InstructionTiming_RTI:
	JSR CycleClockEnd
	STY $500  ; for easy debugging.
	CPY #6
	BNE FAIL_InstructionTiming5
	INC <ErrorCode
	
	;;; Test O [Instruction Timing]: BRK takes 7 cycles ;;;
	LDA #$40
	STA $600
	JSR CycleClockBegin
	BRK
	.byte $00 ; BRK is compiled as 1 byte for some reason.
	JSR CycleClockEnd
	STY $500  ; for easy debugging.
	CPY #6+7+40 ; The 2A07 cycle clock owns the IRQ/BRK vector at $0600 (it measures against the frame IRQ), so a
	            ; BRK reaches this test's RTI through the JMP at $0600 (3) and 37 cycles of the clock's handler
	            ; (CycleClock3_IRQ, counted in its comments): 7 + 6 + 3 + 37. (A first version left out the JMP.)
	BNE FAIL_InstructionTiming5
	INC <ErrorCode
	
	;;; Test P [Instruction Timing]: JMP (indirect) takes 5 cycles ;;;
	LDA #LOW(TEST_InstructionTiming_JMPIndirect)
	STA <$00
	LDA #HIGH(TEST_InstructionTiming_JMPIndirect)
	STA <$01
	JSR CycleClockBegin
	JMP [$0000]
TEST_InstructionTiming_JMPIndirect:
	JSR CycleClockEnd
	STY $500  ; for easy debugging.
	CPY #5
	BNE FAIL_InstructionTiming5

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;
FAIL_InstructionTiming5:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_InstructionTiming_Immediates:
	.byte $09, $29, $49, $69, $A0, $A2, $A9, $C0, $C9, $E0, $E9

TEST_InstructionTiming_ZPs:
	.byte $05, $25, $45, $65, $85, $86, $A5, $A6, $C5, $E5
	
TEST_InstructionTiming_ZP2s:
	.byte $06, $26, $46, $66, $C6, $E6

TEST_InstructionTiming_iZPs:
	.byte $15, $35, $55, $75, $95, $96, $B5, $B6, $D5, $F5
	
TEST_InstructionTiming_iZP2s:
	.byte $16, $36, $56, $76, $D6, $F6

TEST_InstructionTiming_As:
	.byte $0D, $2C, $2D, $4D, $6D, $8C, $8D, $8E, $AC, $AD, $AE, $CC, $CD, $EC, $ED

TEST_InstructionTiming_A2s:
	.byte $0E, $2E, $4E, $6E, $CE, $EE

TEST_InstructionTiming_iAs:
	.byte $99, $9D
	
TEST_InstructionTiming_iAs_plus:
	.byte $19, $1D, $39, $3D, $59, $5D, $79, $7D, $B9, $BC, $BD, $BE, $D9, $DD, $F9, $FD

TEST_InstructionTiming_iA2s:
	.byte $1E, $3E, $5E, $7E, $DE, $FE

TEST_InstructionTiming_inX:
	.byte $01, $21, $41, $61, $81, $A1, $C1, $E1

TEST_InstructionTiming_inY:
	.byte $11, $31, $51, $71, $B1, $D1, $F1

TEST_InstructionTiming_inY_STA:
	.byte $91

TEST_InstructionTiming_Implied:
	CLC
	ASL A
	SEC
	LSR A
	CLI
	ROL A
	SEI
	ROR A
	DEY
	TXA
	TYA
	TXS
	TAY
	TAX
	CLV
	TSX
	INY
	DEX
	CLD
	INX
	NOP
	SED
;;;;;;;

TEST_IFlagLatency_IRQ:
	STX <$50
	LDA #0	
	STA $4010	; disable the DMA IRQ
	STA $4015	; This step should NOT be required, since I'm acknowledging the IRQ.
	LDA $4015	; Acknowledge the APU Frame Counter IRQ as well, for good measure.
	LDA #$40
	STA $4017	; might as well play it extra safe.
	PLA
	STA <$51
	PLA 
	STA <$52
	PLA
	STA <$53
	PHA
	LDA <$52
	PHA
	LDA <$51
	PHA	
	RTI
;;;;;;;

TEST_IFlagLatency_IRQ2:
	INY
	STY <$51
	BEQ TEST_IFlagLatency_IRQ2_DontAcknowledgeIRQ
	STX <$50
	LDA #0	
	STA $4010	; disable the DMA IRQ
	STA $4015	; This step should NOT be required, since I'm acknowledging the IRQ.
TEST_IFlagLatency_IRQ2_DontAcknowledgeIRQ:
	RTI
;;;;;;;

TEST_IFlagLatency_StartTest:
	SEI
	LDA #0
	LDY #$FF
	STA <$50
	STA <$51
	JSR DMASync_50CyclesRemaining
	LDX #0		; +2
	LDA #$8F	; +2
	STA $4010	; +4 (enable the DMA IRQ)
	JSR Clockslide_34 ; +34
	RTS			; +6
;;;;;;;

TEST_IFlagLatency_IRQPrep:
	LDA #$4C
	STA $600
	LDA #LOW(TEST_IFlagLatency_IRQ)
	STA $601
	LDA #HIGH(TEST_IFlagLatency_IRQ)
	STA $602
	RTS
;;;;;;;

FAIL_IFlagLatency1:
	JMP FAIL_IFlagLatency

TEST_IFlagLatency:
	; STATUS: UNVERIFIED [CPU] Tests A and B use the frame counter IRQ; D and E use no DMC (E is built from a program
	; on the stack, PLP and BCC in open bus). The keys are derived from NESdev's interrupt polling rules; no PAL
	; hardware trace yet.
	; How this works.
	; The IRQ occurs when the CPU polls for interrupts, the "IRQ Level Detector" is low, and the I flag of the CPU is not set.
	; As an emulator developer, this poses 2 questions. What sets the IRQ Level Detector low, and when does the CPU poll for interrupts?
	; In an NROM cartridge, there are 2 ways the IRQ Level Detector is set low:
	;	- If the DMC DMA's IRQ flag is set and the final byte of a DMC sample finishes playing. (this is the method used for this test)
	;	- If the APU's frame counter IRQ is enabled, and the frame counter reaches the end of its sequence in mode 0.
	; If the level detector is left low, an IRQ will happen again if the I flag is disabled. (The interrupt sets the I flag. Otherwise it would be an infinite slide of interrupts)
	; The only way the IRQ Level Detector is set high again is by "acknowledging the IRQ".
	; With the DMC DMA IRQ method, we acknowledge the IRQ by writing to $4010 to disable the IRQ.
	;
	; To understand the timing of IRQ Level Detector, We need to talk about a CPU cycle in even more depth.
	; The clock line of the 6502 (called φ0) is used to form two separate clock inputs. "φ1" is raised when φ0 is low. "φ2" is raised when φ0 is high.
	; You can imagine a CPU cycle in 2 halves. φ1 and φ2.
	;    ......:...........:...........:...........:...........:...........:...........:......
	;    ┐     ┌─────┐     ┌─────┐     ┌─────┐     ┌─────┐     ┌─────┐     ┌─────┐     ┌─────┐     
	; φ0 │     │     │     │     │     │     │     │     │     │     │     │     │     │     │  
	;    └─────┘     └─────┘     └─────┘     └─────┘     └─────┘     └─────┘     └─────┘     └
	;    [φ1]  [φ2]  [φ1]  [φ2]  [φ1]  [φ2]  [φ1]  [φ2]  [φ1]  [φ2]  [φ1]  [φ2]  [φ1]  [φ2]  
	; During φ2 of each CPU cycle, (The timing of this is important when it comes to CPU/PPU Clock alignments, since the PPU is clocked 3 times as often as the CPU clock), the IRQ Level Detector is connected to the IRQ line of the 6502.
	; 
	; Finally, let's talk about "interrupt polling"
	; Just because the IRQ line is set (and the I flag is not), that doesn't mean an IRQ will happen on the next CPU cycle.
	; The CPU needs to poll for interrupts, and this happens (typically*) before the final CPU cycle of an instruction. If an interrupt was detected, then the following instruction will be an interrupt. (This also applies to the NMI)
	; *A branch that isn't taken only polls once before the second cycle, while a branch that is taken additionally polls right before the fourth cycle. (in total, 2 polls.)
	;	- This means that a branch that doesn't cross a page boundary will have the "interrupt delay". See the breakdown below.
	;	- BRK seems to poll before cycle 2, 3, 4, and 5, notably not polling before cycles 6 and 7. This might be the cause of "Interrupt Hijacking"?
	;
	; And this process of polling is directly the cause for the latency in clearing the interrupt flag. Here are the order of operations:
	;	- Assume the I flag is set. (Interrupts will not occur until cleared)
	;	- The IRQ Level Detector is pulled low.
	;	- on φ2, this is detected, and the IRQ pin of the 6502 is set.
	;	- a CLI instruction runs:
	;		- Cycle 1: read the opcode, $58. (An interrupt did not occur, so we keep it)
	;		- Interrupt polling: The I flag is set, so the interrupt does not occur.
	;		- Cycle 2, dummy read, and then clear the I flag.
	;	- The next instruction occurs. Let's say it's a NOP.
	;		- Cycle 1: read the opcode, $EA. (An interrupt did not occur, so we keep it)
	;		- Interrupt polling: The I flag is not set, so the interrupt does occur!!!
	;		- Cycle 2: dummy read.
	;	- The next instruction occurs, but now we're running an interrupt!
	;
	; And you can follow this logic to see why the RTI instruction can update the I flag and be followed by another interrupt immediately:
	;	- Assume the I flag is set. (Interrupts will not occur until cleared)
	;	- The IRQ Level Detector is pulled low.
	;	- on φ2, this is detected, and the IRQ pin of the 6502 is set.
	;	- an RTI instruction runs:
	;		- Cycle 1: read the opcode, $40. (An interrupt did not occur, so we keep it)
	;		- Cycle 2: Dummy read
	;		- Cycle 3: Dummy read at the stack pointer
	;		- Cycle 4: Read from the stack, and copy the values to the processor flags. (Updates the I flag) Also increment the address bus low byte.
	;		- Cycle 5: Read from the stack, this value is held in the data latch. Also increment the address bus low byte.
	;		- Interrupt polling: The I flag is not set, so the interrupt does occur!!!
	;		- Cycle 6: Update the low byte of the PC, Read from the stack, update the high byte of the PC, and copy the low byte of the address bus into the stack pointer.
	;	- The next instruction occurs, but now we're running an interrupt, since the I flag was updated before polling!
	;
	; Let's also walk through that example with the branches, since I'll be testing for it.
	;	- Assume the I flag is clear. (Interrupts will occur)
	;	- Assume The IRQ Level Detector is pulled high. (It will be pulled low mid-instruction for this example)
	;	- The Z flag is set.
	;	- A BEQ instruction runs:
	;		- Cycle 1: read the opcode, $F0. (An interrupt did not occur, so we keep it)
	;		- Interrupt polling: The IRQ line is not set, so the interrupt does not occur.
	;		- It's time for φ2, and let's say that this was timed such that the IRQ Level Detector went low just in time for this cycle, so the IRQ line is now set.
	;		- Cycle 2: Read the operand, check the value of the Z Flag. It is set, so the instruction isn't over yet.
	;		- Cycle 3: Dummy read, move the PC according to the value read in the operand. Let's say the page boundary was not crossed. (End of instruction)
	;	- Welp, the interrupts were not polled after the IRQ line was set, so the interrupt won't occur until after the next instruction.
	;
	; And by extension, you can follow this logic for the following instructions:
	; 	- SEI: Polls happen before the I flag is set.
	;	- PLP: Polls happen before the I flag is pulled off the stack.	
	;
	; And the test works by simply running an instruction that updates the I flag, running an INX, then the IRQ should run, storing X somewhere. We can see how long the delay was by measuring the value we stored.

	JSR TEST_IFlagLatency_IRQPrep
	
	LDA #0	
	STX $4010	; disable the DMA IRQ
	LDA #$40
	STA $4017	; disable the frame counter IRQ's

	;;; Test 1 [Interrupt Flag Latency]: Does the IRQ happen at all? ;;;
	JSR TEST_IFlagLatency_StartTest ; clear address $50, and sync with DMA. X=0
	LDA #$5A
	; DMA should happen here.
	STA <$50
	JSR Clockslide_50 ; The timing of the IRQ Level detector is not what we are testing for here, so we'll stall for a bit. We *will* time for that in a few tests, but not right now.
	CLI			; +2
	NOP
	; IRQ should happen here.
	NOP
	LDA <$50	; the IRQ routine will overwrite this value, so it should be $00 instead of $5A
	CMP #00
	BNE FAIL_IFlagLatency1
	INC <ErrorCode

	;;; Test 2 [Interrupt Flag Latency]: Does the IRQ happen immediately after CLI, or after the following instruction? ;;;
	JSR TEST_IFlagLatency_StartTest ; clear address $50, and sync with DMA. X=0
	NOP
	; DMA should happen here.
	JSR Clockslide_50 ; Wait for IRQ to be ready
	INX ; X=1
	CLI
	; The IRQ isn't detected until the end of the *next* instruction.
	INX	; X=2
	; IRQ should happen here.
	INX
	LDA <$50
	CMP #02
	BNE FAIL_IFlagLatency1
	INC <ErrorCode
	
	;;; Test 3 [Interrupt Flag Latency]: Does SEI immediately prevent the IRQ from happening? (it should not) ;;;
	JSR TEST_IFlagLatency_StartTest ; clear address $50, and sync with DMA. X=0
	NOP
	; DMA should happen here.
	JSR Clockslide_50 ; Wait for IRQ to be ready
	INX
	CLI
	SEI
	; The interrupt has already been detected before the I flag was set, so the IRQ will happen here. (The IRQ is acknowledged so it doesn't happen twice/infinitely in this test)
	INX
	LDA <$50
	CMP #01
	BNE FAIL_IFlagLatency1
	INC <ErrorCode

	;;; Test 4 [Interrupt Flag Latency]: Check if the interrupt flag was pushed to the stack in the previous test (it should be) ;;;
	TSX
	DEX
	DEX
	LDA $100, X
	AND #flag_i ; the I flag is #$04
	BEQ FAIL_IFlagLatency1
	INC <ErrorCode

	;;; Test 5 [Interrupt Flag Latency]: Does the IRQ run again immediately after the RTI in SEI CLI? (it should) ;;;
	LDA #LOW(TEST_IFlagLatency_IRQ2)
	STA $601
	LDA #HIGH(TEST_IFlagLatency_IRQ2)	; change the IRQ pointer. This new one only acknowledges the IRQ the second time it occurs.
	STA $602
	JSR TEST_IFlagLatency_StartTest ; clear address $50, and sync with DMA. X=0
	NOP
	; DMA should happen here.
	JSR Clockslide_50 ; Wait for IRQ to be ready
	CLI
	INX
	; IRQ should happen here.
	; Second IRQ should happen here.
	INX ; If this happens before the IRQ, you fail the test.
	SEI
	LDA <$51 ; Did the IRQ run twice? (This uses the Y register, incremented in every IRQ, initialized to $FF, so $FF + 2 = 1. CMP #1.
	CMP #1
	BNE FAIL_IFlagLatency1
	LDA <$50 ; Did the second IRQ run before the second INX?
	CMP #1
	BNE FAIL_IFlagLatency2
	INC <ErrorCode

	;;; Test 6 [Interrupt Flag Latency]: RTI updates the I flag before the check for an interrupt ;;;
	JSR TEST_IFlagLatency_IRQPrep ; Re-set up the original IRQ routine.
	; This next test uses and RTI, so let's set up the return address and flags.
	LDA #HIGH(TEST_IFlagLatency_RTI)
	PHA
	LDA #LOW(TEST_IFlagLatency_RTI)
	PHA
	LDA #flag_i ; the I flag is #$04
	PHA
	JSR TEST_IFlagLatency_StartTest ; clear address $50, and sync with DMA. X=0
	NOP
	; DMA should happen here.
	JSR Clockslide_50 ; Wait for IRQ to be ready
	LDA #$5A
	STA <$50 ; The IRQ routine would overwrite this. The IRQ should not occur in this test.
	CLI
	RTI	
TEST_IFlagLatency_RTI:
	; The IRQ should not occur, as the RTI instruction updates the flags before polling for interrupts. RTI should pull off the flags such that the I flag is set, preventing interrupts.
	INX	; Really not necessary, as the IRQ should not happen, so no matter what the value of X is, if $50 is overwritten, the test fails.
	INX	; Really not necessary, as the IRQ should not happen, so no matter what the value of X is, if $50 is overwritten, the test fails.
	LDA <$50
	CMP #$5A
	BNE FAIL_IFlagLatency2
	INC <ErrorCode

	;;; Test 7 [Interrupt Flag Latency]: Does the IRQ happen immediately after PLP, or after the following instruction? ;;;
	JSR TEST_IFlagLatency_StartTest ; clear address $50, and sync with DMA. X=0
	NOP
	; DMA should happen here.
	JSR Clockslide_50 ; Wait for IRQ to be ready
	LDA #0
	PHA
	PLP	; Pull off the flags. I flag is NOT set.
	INX
	; IRQ should happen here.
	INX ; If this happens before the IRQ, you fail the test.
	LDA <$50
	CMP #01
	BNE FAIL_IFlagLatency2
	INC <ErrorCode
	
	;;; Test 8 [Interrupt Flag Latency]: Does the IRQ happen at the correct CPU cycle? ;;;
	; In order to test the Interrupt polling behavior of branches, we need the IRQ to happen at the correct CPU cycle.
	; Let's check if it does!
	JSR TEST_IFlagLatency_StartTest ; clear address $50, and sync with DMA. X=0
	CLI			; +2
	; DMA should happen here
	INX
	; IRQ should happen here.
	INX
	LDA <$50	; the IRQ routine will overwrite this value, so it should be $00 instead of $5A
	CMP #01
	BNE FAIL_IFlagLatency2
	INC <ErrorCode

	;;; Test 9 [Interrupt Flag Latency]: Do branches poll for interrupts before cycle 2? (They should) ;;;
	JSR TEST_IFlagLatency_StartTest ; clear address $50, and sync with DMA. X=0
	LDA <$50
	; DMA should happen here.
	CMP #$5A
	CLV	; clear overflow flag.
	CLI	
	BVS	TEST_IFlagLatency_Branch1	; This branch will NOT be taken.
TEST_IFlagLatency_Branch1:
	; IRQ should happen here.
	INX 
	LDA <$50
	CMP #$00
	BNE FAIL_IFlagLatency2
	INC <ErrorCode
	
	;;; Test A [Interrupt Flag Latency]: Do branches poll for interrupts before cycle 3? (They should not) ;;;
	; Rebuilt on the frame counter IRQ (the DMC IRQ cannot be raised inside an instruction on a 2A07); see the
	; notes above TEST_IFL_PollSweep_IRQ for the method and its sources.
	JSR TEST_IFlagLatency_TestA
	BNE FAIL_IFlagLatency2
	JSR TEST_IFlagLatency_IRQPrep    ; the original handler, for test B
	INC <ErrorCode
	; This next test needs to occur at a known page boundary, so let's jump to approximately address $FE00.
	; It doesn't return, so the end of the test just happens out there.
	JMP TEST_IFlagLatency_PageBoundaryTest ; TEST B Occurs HERE!

FAIL_IFlagLatency2:
	JMP FAIL_IFlagLatency

TEST_IFlagLatency_Test_C:
	;;; Test C [Interrupt Flag Latency]: A real quick ppu IO open bus pre-requisite check ;;;
	; Test E is pretty wild, and involves jumping to a PPU register. To prevent a crash, I need to verify that jumping there is safe.
	LDA #$44
	STA $2002
	LDA #0
	LDA $3FA5 ; Specifically where the PC will end up at some point during test E
	CMP #$44
	BNE FAIL_IFlagLatency2
	INC <ErrorCode

	;;; Test D [Interrupt Flag Latency]: A real quick open bus pre-requisite check ;;;
	; Test E is pretty wild, and involves jumping to open bus. To prevent a crash, I need to verify that jumping there is safe.
	; Test E uses no DMC DMA (see below), so no DMA pre-test is needed here. What E needs is the PPU I/O latch through
	; a register mirror and the $2007 read buffer.
	LDA #$5A
	STA $2002	; ppu bus is now $5A
	LDX #$10
	LDA $3FF0, X; Read ppu bus, read open bus. (this works on an everdrive too.)
	CMP #$5A
	BNE FAIL_IFlagLatency2
	JSR WaitForVBlank
	JSR DisableRendering
	JSR WriteToPPUADDRWithByte
	.byte $2C, $00
	.byte $60, $FF
	JSR ReadPPUADDRFromWord
	.byte $2C, $00
	CMP #$60
	BNE FAIL_IFlagLatency2 ; the PPU read buffer has to work.
	INC <ErrorCode
	
	;;; Test E [Interrupt Flag Latency]: What if the first poll detects an interrupt, but the flag is cleared before the second poll? ;;;
	; The subject (NESdev "CPU interrupts", branch instructions): a taken branch that crosses a page polls for interrupts
	; before its 2nd cycle and again before its 4th. Here the branch is BCC at $4013:
	; 1.) Read opcode $90 at $4013
	; - poll for interrupts (the frame IRQ is asserted)
	; 2.) Read operand $90 at $4014
	; 3.) Dummy read $4015 (clearing the frame interrupt flag), move PC
	; - poll for interrupts (the IRQ is gone)
	; 4.) Dummy read, update PCH: the branch goes to $4015 - $70 = $3FA5.
	; The IRQ seen by the first poll is still taken, after the branch: the return address pushed is $3FA5.
	;
	; Rebuilt without the DMC DMA and without any timed wait. The 2A03 version used a DMA to put $90 on the bus for
	; the fetch at $4013; the DMA's halted cycles also gave the frame IRQ room to be set between the previous
	; instruction's poll and the BCC's first poll, which needed the DMA and the IRQ to meet within a few cycles after a
	; 33000-cycle wait full of other DMAs. That was never re-derived for the 2A07. This form works on any CPU:
	;   - The frame interrupt flag is set long before, with the I flag set, so nothing happens yet.
	;   - The stack holds a program. LDA <$60 is executed at $3FFE/$3FFF ($A5 from the PPU I/O latch, $60 from the $2007
	;     read buffer; <$60> = $68) and leaves $68 on the bus, so $4000 is fetched as PLA. Each PLA leaves the byte it
	;     pulls on the bus, which is the next opcode: PLAs at $4000-$4011, and the last of them pulls $28: PLP at $4012.
	;     None of these reads $4015 (the last dummy read is $4013).
	;   - The PLP pulls $90. That clears I and C, and $90 is left on the bus: BCC at $4013, operand $90 (open bus) at $4014.
	;     PLP's change to the I flag is delayed by one instruction (tests 1-9 of this test), so the IRQ is not taken
	;     after the PLP: the BCC's first poll is the first one that sees it.
	;   - The $2007 read at $3FFF also leaves $60 in the PPU I/O latch, so $3FA5 (a $2005 mirror) would be fetched as
	;     RTS, which pulls the return address pushed under the program (used when no IRQ is taken).
	; A $4015 read only clears the flag at a put-to-get transition, so the clear is in time for the second poll only
	; when the dummy read is on a put cycle. An OAM DMA fixes the cycle parity, and the test runs twice, the second time
	; one cycle later: one of the two has the dummy read on a put.
	; KEY: both passes push $3FA5. A CPU that only honours the poll before the 4th cycle takes no interrupt in the pass
	; with the read on a put cycle and fails. Derived from NESdev's polling rules; pending hardware.
	; Negative control: a build whose polls overwrite each other and use the live IRQ line fails here, as it
	; fails the 2A03 version of this test.
	LDA #$68
	STA <$60                          ; the opcode LDA <$60 puts on the bus: PLA
	LDA #$4C
	STA $600
	LDA #LOW(TEST_IFL_E_IRQ)
	STA $601
	LDA #HIGH(TEST_IFL_E_IRQ)
	STA $602                          ; the IRQ vector's RAM stub: JMP TEST_IFL_E_IRQ
	LDA #0
	STA <$54                          ; pass 0 or 1: the extra cycle
TEST_IFL_E_Pass:
	SEI
	LDA #0
	STA $4017                         ; 4-step mode, IRQ enabled
	JSR ClockslideFromWord
	.word 33298                       ; PAL frame IRQ: the flag is set now, and its 3 set cycles are long over.
	TSX
	STX <$5D                          ; the stack pointer every exit of this pass restores
	LDA #0
	STA <$52
	STA <$53                          ; return address pushed by the IRQ ($0000 = no IRQ)
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007                         ; read buffer = $60 again (the read at $3FFF refills it from the next address)
	LDA #HIGH(TEST_IFL_E_Ret-1)
	PHA
	LDA #LOW(TEST_IFL_E_Ret-1)
	PHA                               ; for the RTS at $3FA5
	LDA #$90
	PHA                               ; pulled by the PLP: I and C clear, and the BCC opcode on the bus
	LDA #$28
	PHA                               ; the last PLA's pull: PLP
	LDA #$68
	LDX #17
TEST_IFL_E_Push:
	PHA                               ; 17 pulls of PLA
	DEX
	BNE TEST_IFL_E_Push
	LDA #2
	STA $4014                         ; OAM DMA (rendering is off): the CPU resumes on a fixed half of the APU cycle.
	LDA <$54                          ; +3
	JSR Clockslide37_Plus_A           ; +37 + pass: the second pass is one cycle later
	LDA #$A5                          ; +2
	STA $2002                         ; +4  PPU I/O latch = $A5: LDA zp at $3FFE
	JMP $3FFE                         ; +3, then LDA <$60 (3), 18 PLAs (72), PLP (4) and the BCC
TEST_IFL_E_Ret:
	SEI                               ; only reached when no IRQ was taken after the branch
	JMP TEST_IFL_E_PassDone
TEST_IFL_E_IRQ:
	PLA
	STA <$51                          ; flags pushed
	PLA
	STA <$52                          ; return address low
	PLA
	STA <$53                          ; return address high
TEST_IFL_E_PassDone:
	SEI
	LDA #$40
	STA $4017
	LDA $4015                         ; acknowledge
	LDX <$5D
	TXS                               ; drop whatever is left of the stack program
	LDA <$53
	CMP #$3F
	BNE FAIL_IFlagLatency             ; no IRQ, or one from the wrong place: the first poll was not honoured.
	LDA <$52
	CMP #$A5
	BNE FAIL_IFlagLatency
	LDA <$51
	AND #$10
	BNE FAIL_IFlagLatency             ; it has to be an IRQ, not a BRK.
	INC <$54
	LDA <$54
	CMP #2
	BEQ TEST_IFL_E_Done
	JMP TEST_IFL_E_Pass
TEST_IFL_E_Done:

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_IFlagLatency:
	SEI
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;


TEST_NmiAndBrk_BRK:
	INC <$52          ; Increment $52 (We use this outside this routine to check if this routine ran at all.)
	JSR Clockslide_50 ; We need to make sure a significantly incorrect NMI timing won't result in the value of the stack pointer getting stored in <$50
	TSX               ; We want to read the status flags that the BRK pushed to the stack. Transfer the stack pointer to X.
	LDA $101,X        ; Read the flags without running PLA, since PLA pokes them a bit.
	LDX <$50          ; Load X from the loop counter.
	STA $520,X        ; Store the results at $520, X.
	RTI               ; Return.
;;;;;;;;;;;;;;;;;;;;;;;

TEST_NmiAndIrq_IRQ:
	INC <$52          ; Increment $52 (We use this outside this routine to check if this routine ran at all.)
	JSR Clockslide_50 ; We need to make sure a significantly incorrect NMI timing won't result in the value of the stack pointer getting stored in <$50
	TSX               ; We want to read the status flags that the BRK pushed to the stack. Transfer the stack pointer to X.
	LDA $101,X        ; Read the flags without running PLA, since PLA pokes them a bit.
	ORA #4            ;
	STA $101,X        ; I'd prefer if this didn't infinitely loop, and I'd also like to not have to wait for the IRQ line to be set again, so we're not acknowledging it.
	LDX <$50          ; Load X from the loop counter.
	STA $540,X        ; Store the results at $520, X.
	RTI               ; Return.
;;;;;;;;;;;;;;;;;;;;;;;

TEST_NmiAndBrk_NMI:
	INC <$51          ; Increment $51 (We use this outside this routine to check if this routine ran at all.)
	JSR Clockslide_50 ; We're just copying what TEST_NmiAndBrk_BRK did for simplicity.
	TSX               ; We want to read the status flags that the BRK pushed to the stack. Transfer the stack pointer to X.
	LDA $101,X        ; read the flags without running PLA, since PLA pokes them a bit.
	LDX <$50          ; Load X from the loop counter.
	STA $500,X        ; Store the results at $500, X.
	RTI               ; Return.
;;;;;;;;;;;;;;;;;;;;;;;

TEST_NmiAndIrq_NMI:
	INC <$51          ; Increment $52 (We use this outside this routine to check if this routine ran at all.)
	JSR Clockslide_50 ; We need to make sure a significantly incorrect NMI timing won't result in the value of the stack pointer getting stored in <$50
	TSX               ; We want to read the status flags that the BRK pushed to the stack. Transfer the stack pointer to X.
	LDA $101,X        ; Read the flags without running PLA, since PLA pokes them a bit.
	ORA #4            ;
	STA $101,X        ; I'd prefer if this didn't infinitely loop, and I'd also like to not have to wait for the IRQ line to be set again, so we're not acknowledging it.
	LDX <$50          ; Load X from the loop counter.
	STA $500,X        ; Store the results at $520, X.
	RTI               ; Return.
;;;;;;;;;;;;;;;;;;;;;;;
	
	;;;;;;;;;;;;;;;;;;;;;;;
	;;; NMI Overlap BRK ;;;
	;;;;;;;;;;;;;;;;;;;;;;;	
TEST_NmiAndBrk:
	; STATUS: UNVERIFIED [SYNC][CPU] Tests interrupt HIJACKING, not vector forwarding (CPU_ALL documents the B flag). The PAL form
	; checks the order of three runs of results and the length of the hijack window (10 passes = 5 CPU cycles), not
	; a per-pass key; see below. The values are at $500-$53F; not yet run on PAL hardware.
	LDA #$09                           ; We want to write `ORA #$80` at the start of the NMI/BRK routines. This would set the CPU's Negative Flag, which we can see get pushed to the stack if the interrupts are spaced out.
	STA $600                           ; So we write to $600 and $700.
	STA $700                           ;
	LDA #$80                           ;
	STA $601                           ;
	STA $701                           ;
	LDA #$4C                           ; JMP opcode.
	STA $602                           ;
	STA $702                           ;
	LDA #Low(TEST_NmiAndBrk_BRK)       ;
	STA $603                           ;
	LDA #High(TEST_NmiAndBrk_BRK)      ; change the IRQ pointer.
	STA $604                           ;
	LDA #Low(TEST_NmiAndBrk_NMI)       ;
	STA $703                           ;
	LDA #High(TEST_NmiAndBrk_NMI)      ; change the NMI pointer.
	STA $704                           ;
	;;; Test 1 [NMI overlap BRK]: BRK should skip the following byte. ;;;
	; This test is about Interrupt Hijacking.
	; Here's how it works:
	; After an NMI or BRK, read the value pushed to the stack, and store at $500,X or $520,X respectively.
	; Then just read all the values and compare with an answer key.
	;
	; We're going to need to count cycles for every instruction so we can line this up.
	; In an older form of this test, I re-synced to VBlank for every loop, and that resulted in this test taking around 11.5 seconds.
	; I would like this updated version of this test to *not* take that long, so we're only going to sync to VBlank once and then count cycles to make the NMI land at the right time each loop.
	LDX #0                             ; Set X to zero for this upcoming loop.
	TXA                                ;
	JSR VblSync_Plus_A                 ; Sync the next instruction to scanline 241, dot 0. (This takes upwards of a third of a second.)
	                                   ; Rendering is already disabled.
	                                   ; The next NMI is in one frame. (and one ppu cycle... and then one and a half more cpu cycles.)
	LDA $2002                          ; +4 cycles, prevent the NMI from happening
	JSR ClockslideFromWord             ; Wait until the BRK instruction would land just briefly before vblank.
	; PAL form. A PAL frame is 341*312/3.2 = 33247.5 CPU cycles (NESdev "Cycle reference chart"), so a
	; loop of a whole number of CPU cycles can only move the NMI by a multiple of 0.5 cycle (1.6 dots) per pass: a
	; 1-dot sweep, and a 1-dot answer key, are impossible. This test uses a 33248-cycle pass: the NMI moves
	; 0.5 CPU cycle per pass. The CPU samples NMI once per cycle (NESdev "CPU interrupts"), so each CPU cycle of the
	; sweep is hit by exactly two passes.
	; What is checked: the hijack window is a property of the 6502 core inside the 2A07, measured on hardware as 5
	; CPU cycles (15 dots at the 2C02's 3 dots per cycle); at 0.5 cycle per pass that is 10 passes,
	; whatever the CPU/PPU alignment. The results must form three runs in this order, the middle one exactly 10 long:
	;   NMI $A4 / BRK $36 (BRK, then NMI in its handler); NMI $36 / BRK $00 (NMI hijacks the BRK: B set, BRK handler
	;   skipped), exactly 10; NMI $26 / BRK $36 (NMI first, then the BRK).
	; Where the window starts depends on the alignment and the exact NMI delay, so only its length and the order of
	; the runs are checked, not its position.
	.word 33167                        ; Where the sweep starts. NOT checked by this test (only the order of the runs and the
	; hijack length are); it only has to put all three runs inside the 32 passes. Placed by measurement, which put the
	; end of the hijack window at pass 4-5 with 33175: 8 cycles less moves it to pass ~21, so about 11 passes come
	; before the window and 11 after it, a margin of about 5 CPU cycles either way for other CPU/PPU alignments.
	; (The first estimate, 33194, put the window outside the sweep.)
	JSR EnableNMI                      ; +25 cycles.
	SEI                                ; Set up the flags for the test.
	CLC                                ; Set up the flags for the test.
	CLV                                ; Set up the flags for the test.
	CLD                                ; Clear D too. The pushed flags are compared against fixed values,
	                                   ; and an earlier test can leave D set.
	LDA #0                             ; Set up the flags for the test.
TEST_NmiAndBrk_Loop:                   ; One pass is 33248 CPU cycles, 0.5 cycle (1.6 dots) more than a PAL frame (see above).
	NOP                                ; 2 cycles of padding.
	BRK                                ; BRK will return *after* this upcoming INY, since it only gets compiled to [$00]. 180 CPU cycles will pass before the INX instruction.
	INY	                               ; This should get skipped! I repeat: you should not execute this INY instruction. The RTI instruction will return the PC to the INX instruction.
	INC <$50                           ; +3 cycles, Address $50 is the loop counter.
	LDA <$51                           ; +3
	BNE TEST_NmiAndBrk_ConfirmNMI      ; +3 or +90
	                                   ; We have just confirmed the NMI did not happen, which means we need to add an additional 87 CPU cycles. (+1 because the branch here was not taken)
	JSR Clockslide_100Minus12          ; Stall for 88 cycles.
TEST_NmiAndBrk_ConfirmNMI:             ;
	LDA <$52                           ; +3
	BNE TEST_NmiAndBrk_ConfirmBRK      ; +3 or +90
	                                   ; We have just confirmed the BRK did not happen, which means we need to add an additional 87 CPU cycles. (+1 because the branch here was not taken)
	JSR Clockslide_100Minus12          ; Stall for 88 cycles.
TEST_NmiAndBrk_ConfirmBRK:             ;
	                                   ; At this point, we have ran 194 cycles. (not including the NOP at the top of the loop)
	JSR DisableNMI                     ; 30 CPU cycles.
	LDX <$50                           ; +3, load X from the loop counter.
	CPX #$20                           ; +2, Check if X=20, in which case we're done here.
	BEQ TEST_NmiAndBrk_PostLoop        ; else, +2	
	CPY #0                             ;
	BNE FAIL_NmiAndBrk                 ;
	                                   ; The padding below makes the whole pass 33248 CPU cycles in order to make this loop happen 1 ppu cycle later each iteration relative to vblank.
	JSR ClockslideFromWord             ;
	.word 32969                        ; One pass = 32969 + 279 = 33248 CPU cycles, 0.5 more than a 33247.5-cycle
	; PAL frame. 279 is the rest of the pass: the loop body plus, in each of the two slots, either the interrupt
	; handler or the stall that stands in for it (87 cycles either way). Measurements taken while the NMI fires from
	; EnableNMI do not apply: that is outside the part of the pass the stalls balance.
	JSR EnableNMI                      ; 30 CPU cycles.
	LDA #0                             ; +2
	STA <$51                           ; +3
	STA <$52                           ; +3
	CLC                                ; +2
	JMP TEST_NmiAndBrk_Loop            ; +3 and loop.
	                                   ;
TEST_NmiAndBrk_PostLoop:               ;
	INC <ErrorCode                     ;
;;; Test 2 [NMI overlap BRK]: The results form three runs in order (BRK then NMI, NMI hijacks BRK, NMI then BRK), the hijack run exactly 10 passes (5 CPU cycles) long. ;;;
	LDX #0
TEST_NmiAndBrk_Run1:                   ; NMI $A4 / other $36
	LDA $500, X
	AND #$FE                     ; ignore C: it only tells where in the loop tail the NMI landed
	CMP #$A4
	BNE TEST_NmiAndBrk_Run1End
	LDA $520, X
	AND #$FE
	CMP #$36
	BNE FAIL_NmiAndBrk
	INX
	CPX #$20
	BNE TEST_NmiAndBrk_Run1
	JMP FAIL_NmiAndBrk                 ; never left run 1
TEST_NmiAndBrk_Run1End:
	CPX #0
	BEQ FAIL_NmiAndBrk                 ; run 1 empty: the sweep started inside the window
	STX <$57                     ; first pass of run 2
TEST_NmiAndBrk_Run2:                   ; NMI $36 / other $00: the hijack
	LDA $500, X
	AND #$FE                     ; ignore C: it only tells where in the loop tail the NMI landed
	CMP #$36
	BNE TEST_NmiAndBrk_Run2End
	LDA $520, X
	AND #$FE
	CMP #$00
	BNE FAIL_NmiAndBrk
	INX
	CPX #$20
	BNE TEST_NmiAndBrk_Run2
	JMP FAIL_NmiAndBrk                 ; never left run 2
TEST_NmiAndBrk_Run2End:
	TXA
	SEC
	SBC <$57
	CMP #10                       ; hijack window in CPU cycles * 2 passes per cycle
	BNE FAIL_NmiAndBrk
TEST_NmiAndBrk_Run3:                   ; NMI $26 / other $36, to the end
	LDA $500, X
	AND #$FE                     ; ignore C: it only tells where in the loop tail the NMI landed
	CMP #$26
	BNE FAIL_NmiAndBrk
	LDA $520, X
	AND #$FE
	CMP #$36
	BNE FAIL_NmiAndBrk
	INX
	CPX #$20
	BNE TEST_NmiAndBrk_Run3
	;; End Of Test ;;
	LDA #1
	RTS
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

FAIL_NmiAndBrk:
	JMP TEST_Fail

	;;;;;;;;;;;;;;;;;;;;;;;
	;;; NMI Overlap IRQ ;;;
	;;;;;;;;;;;;;;;;;;;;;;;	
TEST_NmiAndIrq:
	; STATUS: UNVERIFIED [SYNC][CPU] Tests interrupt HIJACKING, not vector forwarding (CPU_ALL documents the B flag). The PAL form
	; checks the order of three runs of results and the length of the hijack window (18 passes = 9 CPU cycles), not
	; a per-pass key; see below. The values are at $500-$57F; not yet run on PAL hardware.
	LDA #$09                           ; We want to write `ORA #$80` at the start of the NMI/BRK routines. This would set the CPU's Negative Flag, which we can see get pushed to the stack if the interrupts are spaced out.
	STA $600                           ; So we write to $600 and $700.
	STA $700                           ;
	LDA #$80                           ;
	STA $601                           ;
	STA $701                           ;
	LDA #$4C                           ; JMP opcode.
	STA $602                           ;
	STA $702                           ;
	LDA #Low(TEST_NmiAndIrq_IRQ)       ;
	STA $603                           ;
	LDA #High(TEST_NmiAndIrq_IRQ)      ; change the IRQ pointer.
	STA $604                           ;
	LDA #Low(TEST_NmiAndIrq_NMI)       ;
	STA $703                           ;
	LDA #High(TEST_NmiAndIrq_NMI)      ; change the NMI pointer.
	STA $704                           ;
	;;; Test 1 [NMI overlap IRQ]: What happens when the NMI runs during an IRQ? ;;;
	; This test is also about Interrupt Hijacking, but with an IRQ this time.
	; Here's how it works:
	; After an NMI or IRQ, read the value pushed to the stack, and store at $500,X or $520,X respectively.
	; Then just read all the values and compare with an answer key.
	;
	; We're going to need to count cycles for every instruction so we can line this up.
	; In an older form of this test, I re-synced to VBlank for every loop, and that resulted in this test taking around 11.5 seconds.
	; I would like this updated version of this test to *not* take that long, so we're only going to sync to VBlank once and then count cycles to make the NMI land at the right time each loop.
	JSR DMASync_50CyclesRemaining      ; Enable the DMC
	LDA #$8F                           ;
	STA $4010                          ; Enable the DMC IRQ
	SEI                                ; And prevent the IRQ from occurring.
	LDX #0                             ; Set X to zero for this upcoming loop.
	LDA #0                             ;
	JSR VblSync_Plus_A                 ; Sync the next instruction to scanline 241, dot 0. (This takes upwards of a third of a second.)
	                                   ; Rendering is already disabled.
	                                   ; The next NMI is in one frame. (and one ppu cycle... and then one and a half more cpu cycles.)
	LDA $2002                          ; +4 cycles, prevent the NMI from happening
	JSR ClockslideFromWord             ; Wait until the IRQ instruction would land just briefly before vblank.
	; PAL form. A PAL frame is 341*312/3.2 = 33247.5 CPU cycles (NESdev "Cycle reference chart"), so a
	; loop of a whole number of CPU cycles can only move the NMI by a multiple of 0.5 cycle (1.6 dots) per pass: a
	; 1-dot sweep, and a 1-dot answer key, are impossible. This test uses a 33248-cycle pass: the NMI moves
	; 0.5 CPU cycle per pass. The CPU samples NMI once per cycle (NESdev "CPU interrupts"), so each CPU cycle of the
	; sweep is hit by exactly two passes.
	; What is checked: the hijack window is a property of the 6502 core inside the 2A07, measured on hardware as 9
	; CPU cycles (27 dots at the 2C02's 3 dots per cycle); at 0.5 cycle per pass that is 18 passes,
	; whatever the CPU/PPU alignment. The results must form three runs in this order, the middle one exactly 18 long:
	;   NMI $A4 / IRQ $26 (IRQ, then NMI in its handler); NMI $26 / IRQ $00 (NMI hijacks the IRQ: IRQ handler skipped),
	;   exactly 18; NMI $26 / IRQ $26 (NMI first, then the IRQ).
	; Where the window starts depends on the alignment and the exact NMI delay, so only its length and the order of
	; the runs are checked, not its position.
	.word 33168                        ; the sweep start: 5 cycles later than 33163, with 44 passes ($2C).
	; Measured (with a start of 33163): the valid part of the sweep was: 14 passes NMI-after-IRQ ($A4), 18 passes hijack, 22
	; passes NMI-before-IRQ ($26); before and after that the NMI lands outside the code the test is about (in the
	; EnableNMI call, or before the loop's own flag setup), giving other flag values. 64 passes of 0.5 cycle (32 cycles)
	; are more than that span (27 cycles), so 44 passes are run, placed with about 5 passes (2.5 cycles) of margin at
	; each end. As in TEST_NmiAndBrk, the position is not part of what is checked.
	; Where the sweep starts, NOT checked (see TEST_NmiAndBrk). The IRQ sequence starts
	; at the same time after the sync as the BRK in TEST_NmiAndBrk and its hijack window ends at the same point, but it
	; is 9 cycles long, not 5: 4 cycles earlier than 33167 keeps about 11 passes before it.
	JSR EnableNMI                      ; +25 cycles.
	CLC                                ; Set up the flags for the test.
	CLV                                ; Set up the flags for the test.
	CLD                                ; Clear D too. The pushed flags are compared against fixed values,
	                                   ; and an earlier test can leave D set.
	LDA #0                             ; Set up the flags for the test.
TEST_NmiAndIrq_Loop:                   ; One pass is 33248 CPU cycles, 0.5 cycle (1.6 dots) more than a PAL frame (see above).
	CLI                                ; Enable interrupts.
	NOP                                ; 2 cycles of padding.
	; The IRQ goes here.               ;
	SEI                                ;
	INC <$50                           ; +3 cycles, Address $50 is the loop counter.
	LDA <$51                           ; +3
	BNE TEST_NmiAndIrq_ConfirmNMI      ; +3 or +96
	                                   ; We have just confirmed the NMI did not happen, which means we need to add an additional 93 CPU cycles. (+1 because the branch here was not taken)
	JSR Clockslide_45                  ; Stall for 95 cycles.
	JSR Clockslide_50                  ;
TEST_NmiAndIrq_ConfirmNMI:             ;
	LDA <$52                           ; +3
	BNE TEST_NmiAndIrq_ConfirmIRQ      ; +3 or +96
	                                   ; We have just confirmed the IRQ did not happen, which means we need to add an additional 93 CPU cycles. (+1 because the branch here was not taken)
	JSR Clockslide_45                  ; Stall for 95 cycles.
	JSR Clockslide_50                  ;
TEST_NmiAndIrq_ConfirmIRQ:             ;
	JSR DisableNMI                     ; 30 CPU cycles.
	LDX <$50                           ; +3, load X from the loop counter.
	CPX #$2C                           ; +2, Check if X=20, in which case we're done here.
	BEQ TEST_NmiAndIrq_PostLoop        ; else, +2	
	                                   ; The padding below makes the whole pass 33248 CPU cycles in order to make this loop happen 1 ppu cycle later each iteration relative to vblank.
	JSR ClockslideFromWord             ;
	.word 32957                        ; Measured with 32956 in the intended regime (both handlers inside the
	; measured part of every pass): 33247 cycles (the loop counter's INC writes twice, one cycle apart; the pass is
	; counted between the same write in two passes), so +1 for 33248. The rest of the pass is the loop body plus, in
	; each of the two slots, either the interrupt handler or the stall that stands in for it.
	JSR EnableNMI                      ; 30 CPU cycles.
	LDA #0                             ; +2
	STA <$51                           ; +3
	STA <$52                           ; +3
	JMP TEST_NmiAndIrq_Loop            ; +3 and loop.
	                                   ;
TEST_NmiAndIrq_PostLoop:               ;
	; Leave no DMC IRQ pending. The DMC IRQ enabled at the top of this test is never acknowledged in the loop (the
	; handler only sets I in the pushed flags), and the handler at $600 loads X from $50 without saving it. A pending
	; DMC IRQ let in by a later CLI after the test had returned would set X (the run-all loop's test index) to $40 and
	; send the run-all loop back to earlier tests forever. Writing $4010 with bit 7 clear
	; clears the DMC interrupt flag (NESdev "APU DMC", $4010: "If clear, the interrupt flag is cleared").
	SEI
	LDA #$0F
	STA $4010

;;; Test 2 [NMI overlap IRQ]: The results form three runs in order (IRQ then NMI, NMI hijacks IRQ, NMI then IRQ), the hijack run exactly 18 passes (9 CPU cycles) long. ;;;
	LDX #0
TEST_NmiAndIrq_Run1:                   ; NMI $A4 / other $26
	LDA $500, X
	AND #$FE                     ; ignore C: it only tells where in the loop tail the NMI landed
	CMP #$A4
	BNE TEST_NmiAndIrq_Run1End
	LDA $540, X
	AND #$FE
	CMP #$26
	BNE FAIL_NmiAndIrq
	INX
	CPX #$2C
	BNE TEST_NmiAndIrq_Run1
	JMP FAIL_NmiAndIrq                 ; never left run 1
TEST_NmiAndIrq_Run1End:
	CPX #0
	BEQ FAIL_NmiAndIrq                 ; run 1 empty: the sweep started inside the window
	STX <$57                     ; first pass of run 2
TEST_NmiAndIrq_Run2:                   ; NMI $26 / IRQ $00: the hijack. Ends at the first pass where the IRQ handler ran:
	; the NMI value is $26 both here and in run 3, so the IRQ array decides where run 2 ends.
	LDA $540, X
	AND #$FE
	CMP #$00
	BNE TEST_NmiAndIrq_Run2End
	LDA $500, X
	AND #$FE
	CMP #$26
	BNE FAIL_NmiAndIrq
	INX
	CPX #$2C
	BNE TEST_NmiAndIrq_Run2
	JMP FAIL_NmiAndIrq                 ; never left run 2
TEST_NmiAndIrq_Run2End:
	TXA
	SEC
	SBC <$57
	CMP #18                       ; hijack window in CPU cycles * 2 passes per cycle
	BNE FAIL_NmiAndIrq
TEST_NmiAndIrq_Run3:                   ; NMI $26 / other $26, to the end
	LDA $500, X
	AND #$FE                     ; ignore C: it only tells where in the loop tail the NMI landed
	CMP #$26
	BNE FAIL_NmiAndIrq
	LDA $540, X
	AND #$FE
	CMP #$26
	BNE FAIL_NmiAndIrq
	INX
	CPX #$2C
	BNE TEST_NmiAndIrq_Run3
	;; End Of Test ;;
	LDA #1
	RTS
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

FAIL_NmiAndIrq:
	JMP TEST_Fail

TEST_APU_Prep:
	SEI	; we don't want any interrupts occurring.
	LDA #$40
    STA $4017	; Disable the frame counter IRQ's
    LDA #$01
    STA $4015	; Enable pulse 1 channel.
    LDA #$10
    STA $4000	; Don't infinitely play pulse 1 channel. (and set the volume to be constantly the minimum.)
    LDA #$7f
    STA $4001	; Disable the sweep.
    LDA #$ff
    STA $4002	; Set Pulse 1's Timer Low to the maximum value.
	RTS
;;;;;;;

FAIL_APULengthCounter:
FAIL_AndDisableAudioChannels:
	; So uh- all tests now disable audio channels after the test ends, so this isn't really needed any more.
	; I have removed the STA $4015 business, but everything that already jumps here will still do that.
	JMP TEST_Fail

TEST_APULengthCounter:
	; Special thanks to blargg. I pretty much just copied all of their APU tests, with a few minor changes and additions here and there.
	JSR TEST_APU_Prep
	
	;;; Test 1 [APU Length Counter]: The pulse 1 channel isn't playing yet. ;;;
	LDA $4015
	BNE FAIL_APULengthCounter
	INC <ErrorCode

	;;; Test 2 [APU Length Counter]: Writing to $4003 will start playing audio. ;;;
	LDA #$18
	STA $4003
	LDA $4015
	CMP #1	; The pulse 1 channel should now be playing.
	BNE FAIL_APULengthCounter ; Otherwise, fail the test!
	INC <ErrorCode
	
	;;; Test 3 [APU Length Counter]: The audio will in-fact stop playing if we wait long enough. ;;;
	LDX #15
TEST_APULengthCounter_DelayQuarterSecondLoop:	; Let's wait for 15 frames. About 1/4th of a second.
	JSR Clockslide_PALFrame
	DEX
	BNE TEST_APULengthCounter_DelayQuarterSecondLoop
	LDA $4015
	BNE FAIL_APULengthCounter ; The pulse 1 channel should no longer be playing.
	INC <ErrorCode

	;;; Test 4 [APU Length Counter]: Writing $80 to $4017 will immediately clock the Length Counter. ;;;
	LDA #0
	STA $4017 ; Reset the frame counter.
	LDA #$18
	STA $4003 ; Length = 2. (The upper 5 bits of a value written to $4003 sets the length counter from a value in a look-up-table.)
	; This Look-up-table is the focus of the Length Table test. But for now, let's just assume at least the length of 2 is emulated.
	LDA #$80
	STA $4017 ; Use the 5-step Frame Counter mode. Writing this value clocks the length counters, which now equals 1.
	STA $4017 ; This clocks it again, so it now equals zero. And just like that, the pulse 1 channel is no longer playing audio.
	LDA $4015
	BNE FAIL_APULengthCounter ; The pulse 1 channel should no longer be playing.
	INC <ErrorCode

	;;; Test 5 [APU Length Counter]: Writing $00 to $4017 will not clock the Length Counter. ;;;
	LDA #0
	STA $4017 ; Reset the frame counter.
	LDA #$18
	STA $4003 ; Length = 2.
	LDA #$00
	STA $4017 ; This doesn't clock the length counters.
	STA $4017 ; This doesn't clock the length counters.
	LDA $4015
	CMP #1
	BNE FAIL_APULengthCounter ; The pulse 1 channel should still be playing.
	INC <ErrorCode

	;;; Test 6 [APU Length Counter]: Disabling the audio channel will immediately clear the length counter to zero. ;;;
	LDA #$18
	STA $4003 ; Length = 2.
	LDA #0
	STA $4015 ; stop playing the pulse 1 channel.
	LDA #1
	STA $4015 ; enable the pulse 1 channel again.
	LDA $4015 ; The length counter was reset, so the pulse 1 channel isn't playing.
	BNE FAIL_APULengthCounter1
	INC <ErrorCode

	;;; Test 7 [APU Length Counter]: The length counter cannot be set when the channel is disabled. ;;;
	LDA #0
	STA $4015 ; stop playing the pulse 1 channel.
	LDA #$18
	STA $4003 ; Length would be 2, but the channel is disabled, so the length is 0.
	LDA #1
	STA $4015 ; enable the pulse 1 channel again.
	LDA $4015 ; The pulse 1 channel isn't playing.
	BNE FAIL_APULengthCounter1
	INC <ErrorCode
	
	;;; Test 8 [APU Length Counter]: If the channel is set to play infinitely, it won't clock the length counter. ;;;
	LDA #0
	STA $4017 ; Reset the frame counter.
	LDA #$18
	STA $4003 ; Length = 2.
	LDA #$30
	STA $4000 ; loop channel infinitely
	LDA #$80
	STA $4017 ; Attempt to clock the counter.
	STA $4017 ; This doesn't work since it's playing infinitely.
	LDA #$10
	STA $4000 ; stop looping channel infinitely. The counters should still be 2.
	LDA $4015
	CMP #1
	BNE FAIL_APULengthCounter1 ; The pulse 1 channel should still be playing.
	INC <ErrorCode
	
	;;; Test 9 [APU Length Counter]: If the channel is set to play infinitely, the length counter is left unchanged. ;;;
	; For the most part, I just copied what blargg did for this entire test.
	; I added an extra test here at the end, since I can imagine an emulator setting the length counter to be something like, $FF every APU cycle in which it's set to loop forever.
	; That's certainly *a way* to make it last forever, but it's not what actually happens, so let's test for that.
	LDA #0
	STA $4017 ; Reset the frame counter.
	LDA #$18
	STA $4003 ; Length = 2.
	LDA #$30
	STA $4000 ; loop channel infinitely
	LDA #$80
	STA $4017 ; Attempt to clock the counter.
	STA $4017 ; This doesn't work since it's playing infinitely.
	LDA #$10
	STA $4000 ; stop looping channel infinitely. The counters should still be 2.
	LDA #$80
	STA $4017 ; Attempt to clock the counter.
	STA $4017 ; It actually will work this time.
	LDA $4015
	BNE FAIL_APULengthCounter1 ; The pulse 1 channel should no longer be playing.
	INC <ErrorCode

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_APULengthCounter1:
FAIL_APULengthTable:
	JMP FAIL_AndDisableAudioChannels
;;;;;;;;;;;;;;;;;
	
TEST_APULengthTable:
	;;; Test 1 [APU Length Table]: Does this emulator pass the APU Length Counter test? It's a pre-requisite. ;;;
	
	JSR TEST_APULengthCounter
	LDX #1
	STX <ErrorCode
	CMP #1
	BNE FAIL_APULengthTable
	INC <ErrorCode

	;;; Test 2 [APU Length Table]: What value was the length counter when we write 'n' to address $4003? ;;;
	; Just for clarification, this is actually "Test 2" through "Test X". They all use the same routine, but the error code is adjusted accordingly.
	LDX #0
TEST_APULengthTableLoop:
	TXA
	ASL A
	ASL A
	ASL A ; The upper five bits of A are now the iteration into this loop.
	PHA
	LDA #0
	STA $4017 ; Reset the frame counter.
	PLA
	STA $4003 ; Reset the length counter with the next value for the test.
	LDY #0
TEST_APULengthTable_UpdateCounterLoop:
	LDA #$80
	STA $4017 ; Clock the length counter.
	INY
	LDA $4015	; Check if pulse 1 is still playing.
	BNE TEST_APULengthTable_UpdateCounterLoop ; Loop until it stops.
	; And just like that, we know the value of the length Table, which is now stored in Y.
	TYA
	CMP TEST_APULengthTable_AnswerKey, X
	BNE FAIL_APULengthTable
	INC <ErrorCode
	INX
	CPX #32
	BNE TEST_APULengthTableLoop
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;
	
TEST_APULengthTable_AnswerKey:
	.byte 10, 254, 20, 2, 40, 4, 80, 6, 160, 8
	.byte 60, 10, 14, 12, 26, 14, 12, 16
	.byte 24, 18, 48, 20, 96, 22, 192, 24
	.byte 72, 26, 16, 28, 32, 30

FAIL_FrameCounterIRQ:
	LDA #$40
	STA $4017	; disable the IRQ flag.
	JMP TEST_Fail

TEST_FrameCounterIRQ:
	SEI
	;;; Test 1 [APU Frame Counter IRQ]: The IRQ flag is set when the APU Frame counter is in the 4-step mode, and the IRQ flag is enabled. ;;;
	LDA #$00	
	STA $4017	; 4-step mode, enable IRQ
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	LDA $4015
	BEQ FAIL_FrameCounterIRQ
	INC <ErrorCode

	;;; Test 2 [APU Frame Counter IRQ]: The IRQ flag is not set when the APU Frame counter is in the 4-step mode, and the IRQ flag is disabled. ;;;
	LDA #$40
	STA $4017	; 4-step mode, disable IRQ
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	LDA $4015
	BNE FAIL_FrameCounterIRQ
	INC <ErrorCode
	
	;;; Test 3 [APU Frame Counter IRQ]: The IRQ flag is not set when the APU Frame counter is in the 5-step mode, and the IRQ flag is enabled. ;;;
	LDA #$80
	STA $4017	; 5-step mode, enable IRQ (it doesn't happen in 5-step mode)
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	LDA $4015
	BNE FAIL_FrameCounterIRQ
	INC <ErrorCode
	
	;;; Test 4 [APU Frame Counter IRQ]: The IRQ flag is not set when the APU Frame counter is in the 5-step mode, and the IRQ flag is disabled. ;;;
	LDA #$C0
	STA $4017	; enable the frame counter IRQ, and use the 5-step mode.
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	LDA $4015
	BNE FAIL_FrameCounterIRQ
	INC <ErrorCode
	
	;;; Test 5 [APU Frame Counter IRQ]: Reading the IRQ flag clears the IRQ flag. ;;;
	LDA #$00	
	STA $4017	; 4-step mode, enable IRQ
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	LDA $4015 ; read it, clearing it
	LDA $4015 ; read it again, but it's already cleared.
	BNE FAIL_FrameCounterIRQ
	INC <ErrorCode
	
	;;; Test 6 [APU Frame Counter IRQ]: The IRQ flag should be cleared when the APU transitions from a "put" cycle to a "get" cycle.  ;;;
	LDA #$00	
	STA $4017	; 4-step mode, enable IRQ
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	JSR OAMDMAWithPage2 ; align with "get" cycle.
	LDA #0 ; (get), (put)
	LDX #0 ; (get), (put)
	; SLO Absolute, X is checked by the unofficial-opcode tests and by [Controller Clocking] test 3; if it is not
	; implemented this test fails here as well.
	.byte $1F	; (get) : SLO Absolute, X 
	.word $4015 ; (put), (get), (put), (get), (put), (get) : This reads from $4015 twice!
	BNE FAIL_FrameCounterIRQ ; If SLO is properly emulated, you might see bit 7 set here (failing the test). The flag is actually cleared before the second read, so bit 7 should be 0.
	INC <ErrorCode
	
	;;; Test 7 [APU Frame Counter IRQ]: The IRQ flag should not be cleared when the APU transitions from a "get" cycle to a "put" cycle. ;;;
	; If you are reading this, then you probably passed test 6 and failed test 7.
	; This was a brand new discovery as of writing this ROM, so I expect most emulators to fail this.
	;
	; When reading from $4015, bit 6 will be cleared. This is known behavior (and the focus of test 5)
	; However, bit 6 will not be cleared until the next "get" cycle.
	; For instance here's what happened during test 6:
	; (get) [Read Opcode: $1F]
	; (put) [Read Operand: $15]
	; (get) [Read Operand: $40]
	; (put) [Read $4015] (this is a put cycle, so afterwards, as the APU transitions into a get cycle, clear bit 6 of 4015)
	; (get) [Read $4015] (bit 6 was just cleared before the read.)
	;
	; And here's what will happen in this test:
	; (put) [Read Opcode: $1F]
	; (get) [Read Operand: $15]
	; (put) [Read Operand: $40]
	; (get) [Read $4015] (this is a get cycle. The APU will not clear bit 6 of 4015 until after the next cycle.)
	; (put) [Read $4015] (bit 6 was still set when this was read. After this cycle, as the APU transitions into a get cycle, we clear bit 6 of $4015.)
	;
	; And of course, in the event of a regular non-double-read, $4015 will still only clear bit 6 on the next get cycle,
	; so you probably want to clear bit 6 inside the APU cycle code of your emulator, and not in your "read $4015" code.
	; I suggest making a flag for "we are clearing bit 6 on the next APU get cycle" to be set inside the "read $4015" code.
	
	LDA #$00	
	STA $4017	; 4-step mode, enable IRQ
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	JSR OAMDMAWithPage2 ; align with "get" cycle.
	LDA <$00  ; (get), (put), (get)
	LDA #0    ; (put), (get)
	LDX #0    ; (put), (get)
	.byte $1F ; (put) : SLO Absolute, X 
	.word $4015;(get), (put), (get), (put), (get), (put) This reads from $4015 twice!
	BEQ FAIL_FrameCounterIRQ2 ; If SLO is properly emulated, bit 7 will be set if you passed the test. The frame counter interrupt flag gets cleared after the second read in this case.
	INC <ErrorCode

	;;; Test 8 [APU Frame Counter IRQ]: Changing the Frame Counter to 5-step mode after the flag was set does not clear the flag. ;;;
	LDA #$00	
	STA $4017 ; 4-step mode, enable IRQ
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	LDA #$80
	STA $4017 ; 5-step mode, enable IRQ
	LDA $4015 ; read the IRQ flag, which will still be set.
	BEQ FAIL_FrameCounterIRQ2
	INC <ErrorCode
	
	;;; Test 9 [APU Frame Counter IRQ]: Disabling the IRQ flag will clear the IRQ flag. ;;;
	LDA #$00	
	STA $4017	; 4-step mode, enable IRQ
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	LDA #$40
	STA $4017 ; clear the IRQ flag.
	LDA $4015 ; read the IRQ flag, which will no longer be set.
	BNE FAIL_FrameCounterIRQ2
	INC <ErrorCode
	
	;;; Test A [APU Frame Counter IRQ]: Test the timing of the IRQ flag. (see if it's set too early) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync CPU with "get" cycle
	LDA #$40  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, clear IRQ flag 
	LDA #$00  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, enable IRQ. (The CPU was on "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.) 
	; the flag should be enabled in 33254 CPU cycles.
	; So let's stall for 33250 cycles, and read $4015 to see if the flag was set. That should be 1 cycle too early.
	JSR ClockslideFromWord
	.word 33250
	LDA $4015 ; If the flag *is* set, it was set too early, so you fail the test.
	BNE FAIL_FrameCounterIRQ2
	INC <ErrorCode
	BNE TEST_FrameCounterIRQ_Continue
	
FAIL_FrameCounterIRQ2:
	LDA #$40
	STA $4017	; disable the IRQ flag.
	JMP TEST_Fail
	
TEST_FrameCounterIRQ_Continue:
	;;; Test B [APU Frame Counter IRQ]: Test the timing of the IRQ flag. (see if it's set on the right CPU cycle) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync CPU with "get" cycle
	LDA #$40  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, clear IRQ flag 
	LDA #$00  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, enable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	; the flag should be enabled in 33254 CPU cycles.
	; So let's stall for 33251 cycles, and read $4015 to see if the flag was set. That should be 1 cycle too early.
	JSR ClockslideFromWord
	.word 33251
	LDA $4015 ; If the flag is *not* set, it was set too late, so you fail the test.
	BEQ FAIL_FrameCounterIRQ2
	INC <ErrorCode

	;;; Test C [APU Frame Counter IRQ]: Test the timing of the IRQ flag. (If the write occurs on a "get" CPU cycle, the IRQ is delayed by 1 CPU cycle) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync CPU with "get" cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag
	LDA #$00  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get), 4-step mode, enable IRQ (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the flag should be enabled in 33255 CPU cycles.
	; So let's stall for 33251 cycles, and read $4015 to see if the flag was set. That should be 1 cycle too early.
	JSR ClockslideFromWord
	.word 33251
	LDA $4015 ; If the flag *is* set, it was set too early, so you fail the test.
	BNE FAIL_FrameCounterIRQ2
	INC <ErrorCode

	;;; Test D [APU Frame Counter IRQ]: Test the timing of the IRQ flag. (see if it's set on the correct cycle) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag
	LDA #$00  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, enable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the flag should be enabled in 33255 CPU cycles.
	; So let's stall for 33252 cycles, and read $4015 to see if the flag was set. That should be *the* cycle it gets set.
	JSR ClockslideFromWord
	.word 33252
	LDA $4015 ; If the flag is *not* set, it was set too late, so you fail the test.
	BEQ FAIL_FrameCounterIRQ2
	INC <ErrorCode

	;;; Test E [APU Frame Counter IRQ]: Reading $4015 on the same cycle the IRQ flag is set, will not clear the IRQ flag (it gets set again on the following 2 CPU cycles) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag
	LDA #$00  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, enable IRQ (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	JSR ClockslideFromWord
	.word 33251
	LDA $4015 ; Read on the same cycle the IRQ flag is set.
	LDA $4015 ; Read again! But it won't be cleared, since the IRQ flag gets set again.
	BEQ FAIL_FrameCounterIRQ3
	INC <ErrorCode
	
	;;; Test F [APU Frame Counter IRQ]: Reading $4015 on the cycle after the IRQ flag is set, will not clear the IRQ flag (it gets set again on the following CPU cycle) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag
	LDA #$00  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, enable IRQ (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	JSR ClockslideFromWord
	.word 33252
	LDA $4015 ; Read on the same cycle the IRQ flag is set.
	LDA $4015 ; Read again! But it won't be cleared, since the IRQ flag gets set again.
	BEQ FAIL_FrameCounterIRQ3
	INC <ErrorCode
	
	;;; Test G [APU Frame Counter IRQ]: Reading $4015 2 cycles after the IRQ flag is set, will not clear the IRQ flag (it gets set again on this CPU cycle) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag
	LDA #$00  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, enable IRQ (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	JSR ClockslideFromWord
	.word 33253
	LDA $4015 ; Read on the same cycle the IRQ flag is set.
	LDA $4015 ; Read again! But it won't be cleared, since the IRQ flag gets set again.
	BEQ FAIL_FrameCounterIRQ3
	INC <ErrorCode
	
	;;; Test H [APU Frame Counter IRQ]: Reading $4015 3 cycles after the IRQ flag is set, will clear the IRQ flag (it does not get set again on this CPU cycle) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag
	LDA #$00  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, enable IRQ (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	JSR ClockslideFromWord
	.word 33254
	LDA $4015 ; Read on the same cycle the IRQ flag is set.
	LDA $4015 ; Read again! But it will be cleared.
	BNE FAIL_FrameCounterIRQ3
	INC <ErrorCode
	BNE TEST_FrameCounterIRQ_Continue2
		
FAIL_FrameCounterIRQ3:
	LDA #$40
	STA $4017	; disable the IRQ flag.
	JMP TEST_Fail
	
TEST_FrameCounterIRQ_Continue2:
	;;; Test I [APU Frame Counter IRQ]: Despite the "Suppress Frame Counter Interrupts flag" being set, the frame counter interrupt flag *will be set* for 2 CPU cycles. (this is timed 1 cycle too early) ;;;
	; This is a fairly recent discovery as of writing this test, so I'm expecting some emulators to fail this one.
	; Let me break this down:
	; 33252 Cycles after frame counter reset: $4015.6 is set to 1.
	; 33253 Cycles after frame counter reset: $4015.6 is set to 1. (The IRQ Level detector is only pulled low if the "Suppress Frame Counter Interrupts flag" is false)
	; 33254 Cycles after frame counter reset: $4015.6 is set according to the "Suppress Frame Counter Interrupts flag". (The IRQ Level detector is only pulled low if the "Suppress Frame Counter Interrupts flag" is false)
	;
	; The following 4 tests will check 33251, 33252, 33253, and 33254 cycles after resetting the frame counter, and the test after that will verify that the IRQ level detector is not pulled low. (An IRQ did not happen)
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the flag should be enabled in 33255 CPU cycles.
	; So let's stall for 33251 cycles, and read $4015 to see if the flag was set. That should be *the* cycle it gets set.
	JSR ClockslideFromWord
	.word 33251
	LDA $4015
	AND #$40
	BNE FAIL_FrameCounterIRQ3
	INC <ErrorCode

	;;; Test J [APU Frame Counter IRQ]: Despite the "Suppress Frame Counter Interrupts" flag being set, the frame counter interrupt flag *will be set* for 2 CPU cycles. (It happens on this cycle) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the flag should be enabled in 33255 CPU cycles.
	; So let's stall for 33252 cycles, and read $4015 to see if the flag was set. That should be *the* cycle it gets set.
	JSR ClockslideFromWord
	.word 33252
	LDA $4015
	AND #$40
	BEQ FAIL_FrameCounterIRQ3
	INC <ErrorCode

	;;; Test K [APU Frame Counter IRQ]: Despite the "Suppress Frame Counter Interrupts" flag being set, the frame counter interrupt flag *will be set* for 2 CPU cycles. (It happens on this cycle too) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the flag should be enabled in 33255 CPU cycles.
	; So let's stall for 33253 cycles, and read $4015 to see if the flag was set. That should be *the* cycle it gets set.
	JSR ClockslideFromWord
	.word 33253
	LDA $4015
	AND #$40
	BEQ FAIL_FrameCounterIRQ4
	INC <ErrorCode

	;;; Test L [APU Frame Counter IRQ]:  Despite the "Suppress Frame Counter Interrupts" flag being set, the frame counter interrupt flag *will be set* for 2 CPU cycles. (It does not happen on this cycle) ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the flag should be enabled in 33255 CPU cycles.
	; So let's stall for 33254 cycles, and read $4015 to see if the flag was set. That should be *the* cycle it gets set.
	JSR ClockslideFromWord
	.word 33254
	LDA $4015
	AND #$40
	BNE FAIL_FrameCounterIRQ4
	INC <ErrorCode

	;;; Test M [APU Frame Counter IRQ]: Despite the frame counter interrupt flag being set for those two cycles, an IRQ will not occur even if the CPU I flag is clear. ;;;
	JSR TEST_IFlagLatency_IRQPrep
	; This test is only reliable if the Interrupt Flag Latency test passes.
	JSR WaitForVBlank
	LDX #$5A
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$40  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the flag should be enabled in 33255 CPU cycles.
	; So let's stall for 33252 cycles, and read $4015 to see if the flag was set. That should be *the* cycle it gets set.
	JSR ClockslideFromWord
	.word 33251
	CLI
	SEI	;[Read Opcode] [Poll for interrupts, and Dummy Read cycle]
	LDA <$50
	CMP #$5A
	BEQ FAIL_FrameCounterIRQ4
	INC <ErrorCode

	;;; Test N [APU Frame Counter IRQ]: If the CPU's I flag is clear, when exactly does the IRQ occur? ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$00  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the IRQ should occur in 33258 CPU cycles.
	JSR ClockslideFromWord
	.word 33248
	CLI
	LDX #0
	INX
	INX
	INX
	INX
	LDA <$50
	CMP #3
	BNE FAIL_FrameCounterIRQ4
	INC <ErrorCode
	BNE TEST_FrameCounterIRQ_Continue3
	
FAIL_FrameCounterIRQ4:
	JMP FAIL_AndDisableAudioChannels

TEST_FrameCounterIRQ_Continue3:
	;;; Test O [APU Frame Counter IRQ]: If the CPU's I flag is clear, when exactly does the IRQ occur? ;;;
	JSR WaitForVBlank
	JSR OAMDMAWithPage2 ; sync with "get" CPU cycle
	LDA <$00  ; (get), (put), (get)
	LDA #$00  ; (put), (get)
	STA $4017 ; (put), (get), (put), (get) : 4-step mode, clear IRQ flag (The CPU was on a "get" cycle when writing that, so the frame counter is reset in 4 CPU cycles.)
	; the IRQ should occur in 33257 CPU cycles.
	JSR ClockslideFromWord
	.word 33249
	CLI
	LDX #0
	INX
	INX
	INX
	INX
	LDA <$50
	CMP #2
	BNE FAIL_FrameCounterIRQ4


	;; END OF TEST ;;
	SEI
	LDA #1
	RTS
;;;;;;;

FAIL_FrameCounter4Step:
	JMP FAIL_AndDisableAudioChannels
;;;;;;;;;;;;;;;;;

; PAL 2A07 frame-sequencer reference: the 4-step half-frame clocks are at
; 16627, 33253, and 49881 CPU cycles after the sequencer reset. TEST 3/5 are
; the "one cycle before" reads, while TEST 4/6 read on the clock cycle.
TEST_FrameCounter4Step:
	JSR TEST_APU_Prep
	;;; Test 1 [APU Frame Counter 4-Step Mode]: Verify the timing of the first clock (read 1 cycle early. It's still going) ;;;
	JSR OAMDMAWithPage2
	; CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$18  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 2.
	LDA #$80  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Manually clock the pulse 1 length counter.
	LDA #$40  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	NOP  ; stall for frame counter to be reset.
	; Okay, the first time the length counters get clocked is in 16627 CPU cycles.
	JSR ClockslideFromWord
	.word 16614 ; 13 cycles to go.
	NOP ; 11 cycles to go
	NOP ; 9 cycles to go
	NOP ; 7 cycles to go
	LDA <$00 ; 4 cycles
	LDA $4015 ; the pulse channel should still be playing for 1 more cycle.
	BEQ FAIL_FrameCounter4Step
	INC <ErrorCode
	
	;;; Test 2 [APU Frame Counter 4-Step Mode]: Verify the timing of the first clock  (Read the cycle it stops);;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$18  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 2.
	LDA #$80  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Manually clock the pulse 1 length counter.
	LDA #$40  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	NOP  ; stall for frame counter to be reset.
	; Okay, the first time the length counters get clocked is in 16627 CPU cycles.
	JSR ClockslideFromWord
	.word 16614 ; 13 cycles to go.
	NOP ; 11 cycles to go
	NOP ; 9 cycles to go
	NOP ; 7 cycles to go
	NOP ; 5 cycles to go
	NOP ; 3 cycles to go
	LDA $4015 ; the pulse channel should have stopped just before you read.
	BNE FAIL_FrameCounter4Step
	INC <ErrorCode
	
	;;; Test 3 [APU Frame Counter 4-Step Mode]: Verify the timing of the second clock while not inhibiting Frame Counter IRQs (read 1 cycle early. It's still going) ;;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #$18  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Set the length to 2. We don't need to manually clock this one, as we're checking the timing of the 2nd clock.
	LDA #$40  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	NOP  ; stall for frame counter to be reset.
	; Okay, the second time the length counters get clocked is in 33253 CPU cycles.
	JSR ClockslideFromWord
	.word 33243 ; PAL 2A07: read one cycle before the 33253-cycle half-frame clock
	NOP ; 7 cycles to go
	LDA <$00  ; 4 cycles to go
	LDA $4015 ; the pulse channel should still be playing for 1 more cycle.
	AND #$01  ; If you passed the Frame Counter IRQ test, bit 6 of $4015 should be set here, so it's very important we run AND #1
	BEQ FAIL_FrameCounter4Step
	INC <ErrorCode
	
	;;; Test 4 [APU Frame Counter 4-Step Mode]: Verify the timing of the second clock while not inhibiting Frame Counter IRQs (Read the cycle it stops) ;;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #$18  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Set the length to 2. We don't need to manually clock this one, as we're checking the timing of the 2nd clock.
	LDA #$40  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	NOP  ; stall for frame counter to be reset.
	; Okay, the second time the length counters get clocked is in 33253 CPU cycles.
	JSR ClockslideFromWord
	.word 33245 ; 9 cycles to go
	NOP ; 7 cycles to go
	NOP ; 5 cycles to go
	NOP ; 3 cycles to go
	LDA $4015; the pulse channel should have stopped just before you read.
	AND #$01 ; If you passed the Frame Counter IRQ test, bit 6 of $4015 should be set here, so it's very important we run AND #1
	BNE FAIL_FrameCounter4Step2
	INC <ErrorCode
	
	;;; Test 5 [APU Frame Counter 4-Step Mode]: Verify the timing of the third clock (read 1 cycle early. It's still going) ;;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$28  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 4.
	LDA #$80  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Manually clock the pulse 1 length counter.
	LDA #$40  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	NOP  ; stall for frame counter to be reset.
	; Okay, the third time the length counters get clocked is in 49881 CPU cycles.
	JSR ClockslideFromWord
	.word 49868 ; 13 cycles to go.
	NOP ; 11 cycles to go
	NOP ; 9 cycles to go
	NOP ; 7  cycles to go
	LDA <$00 ; 4  cycles to go
	LDA $4015 ; the pulse channel should still be playing for 1 more cycle.
	BEQ FAIL_FrameCounter4Step2
	INC <ErrorCode	
	
	;;; Test 6 [APU Frame Counter 4-Step Mode]: Verify the timing of the third clock  (Read the cycle it stops) ;;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$28  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 4.
	LDA #$80  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Manually clock the pulse 1 length counter.
	LDA #$40  ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : 4-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	NOP  ; stall for frame counter to be reset.
	; Okay, the third time the length counters get clocked is in 49881 CPU cycles.
	JSR ClockslideFromWord
	.word 49868 ; 13 cycles to go.
	NOP ; 11 cycles to go
	NOP ; 9 cycles to go
	NOP ; 7 cycles to go
	NOP ; 5 cycles to go
	NOP ; 3 cycles to go
	LDA $4015 ; the pulse channel should have stopped just before you read.
	BNE FAIL_FrameCounter4Step2	
	INC <ErrorCode	
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;
	
FAIL_FrameCounter4Step2:
	JMP FAIL_AndDisableAudioChannels

FAIL_FrameCounter5Step:
	JMP FAIL_AndDisableAudioChannels
;;;;;;;;;;;;;;;;;

; PAL 2A07 frame-sequencer reference: the 5-step half-frame clocks are at
; 16627, 41565, and 58193 CPU cycles after the sequencer reset. The third
; value is 41566 (end of sequence) plus the next 16627-cycle half-frame.
TEST_FrameCounter5Step:
	JSR TEST_APU_Prep
	;;; Test 1 [APU Frame Counter 5-Step Mode]: Verify the timing of the first clock (read 1 cycle early. It's still going) ;;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$18  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 2.
	LDA #$80  ; (get), (put)               : This upcoming write will clock it once, then we just need to wait for the second clock.
	STA $4017 ; (get), (put), (get), (put) : 5-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	LDA <$00  ; stall for 3 CPU cycles.
	; Okay, the first time the length counters get clocked is in 16627 CPU cycles.
	JSR ClockslideFromWord
	.word 16614 ; 12 cycles to go.
	NOP ; 10 cycles to go
	NOP ; 8 cycles to go
	NOP ; 6 cycles to go
	NOP ; 4 cycles
	LDA $4015 ; the pulse channel should still be playing for 1 more cycle.
	BEQ FAIL_FrameCounter5Step
	INC <ErrorCode
	
	;;; Test 2 [APU Frame Counter 5-Step Mode]: Verify the timing of the first clock  (Read the cycle it stops);;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$18  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 2.
	LDA #$80  ; (get), (put)               : This upcoming write will clock it once, then we just need to wait for the second clock.
	STA $4017 ; (get), (put), (get), (put) : 5-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	LDA <$00  ; stall for 3 CPU cycles.
	; Okay, the first time the length counters get clocked is in 16627 CPU cycles.
	JSR ClockslideFromWord
	.word 16614 ; 12 cycles to go.
	NOP ; 10 cycles to go
	NOP ; 8 cycles to go
	NOP ; 6 cycles to go
	LDA <$00 ; 3 cycle to go
	LDA $4015 ; the pulse channel should have stopped just before you read.
	BNE FAIL_FrameCounter5Step
	INC <ErrorCode
	
	;;; Test 3 [APU Frame Counter 5-Step Mode]: Verify the timing of the second clock (read 1 cycle early. It's still going) ;;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$28  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 4.
	LDA #$80  ; (get), (put)               : This upcoming write will clock it once, then we just need to wait for the second clock.
	STA $4017 ; (get), (put), (get), (put) : clock it an extra time.
	STA $4017 ; (get), (put), (get), (put) : 5-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	LDA <$00  ; stall for 3 CPU cycles.
	; Okay, the second time the length counters get clocked is in 41574 CPU cycles.
	JSR ClockslideFromWord
	.word 41554 ; PAL 2A07: read one cycle before the 41565-cycle half-frame clock
	NOP ; 8 cycles to go
	NOP ; 6 cycles to go
	NOP ; 4 cycles
	LDA $4015 ; the pulse channel should still be playing for 1 more cycle.
	BEQ FAIL_FrameCounter5Step
	INC <ErrorCode
	
	;;; Test 4 [APU Frame Counter 5-Step Mode]: Verify the timing of the second clock  (Read the cycle it stops);;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$28  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 4.
	LDA #$80  ; (get), (put)               : This upcoming write will clock it once, then we just need to wait for the second clock.
	STA $4017 ; (get), (put), (get), (put) : clock it an extra time.
	STA $4017 ; (get), (put), (get), (put) : 5-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	LDA <$00  ; stall for 3 CPU cycles.
	; Okay, the second time the length counters get clocked is in 41574 CPU cycles.
	JSR ClockslideFromWord
	.word 41554 ; PAL 2A07: read one cycle before the 41565-cycle half-frame clock
	NOP ; 8 cycles to go
	NOP ; 6 cycles to go
	LDA <$00 ; 3 cycle to go
	LDA $4015 ; the pulse channel should have stopped just before you read.
	BNE FAIL_FrameCounter5Step2
	INC <ErrorCode
	
	;;; Test 5 [APU Frame Counter 5-Step Mode]: Verify the timing of the third clock (read 1 cycle early. It's still going) ;;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$28  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 4.
	LDA #$80  ; (get), (put)               : This upcoming write will clock it once, then we just need to wait for the second clock.
	STA $4017 ; (get), (put), (get), (put) : 5-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	LDA <$00  ; stall for 3 CPU cycles.
	; Okay, the third time the length counters get clocked is in 58213 CPU cycles.
	JSR ClockslideFromWord
	.word 58178 ; PAL 2A07: read one cycle before the next 58193-cycle half-frame clock
	NOP ; 12 cycles to go
	NOP ; 10 cycles to go
	NOP ; 8 cycles to go
	NOP ; 6 cycles to go
	LDA $4015 ; the pulse channel should still be playing for 1 more cycle.
	BEQ FAIL_FrameCounter5Step2
	INC <ErrorCode
	
	;;; Test 6 [APU Frame Counter 5-Step Mode]: Verify the timing of the third clock  (Read the cycle it stops);;;
	JSR OAMDMAWithPage2
	;CPU is synced with "get" CPU cycle
	LDA #0    ; (get), (put)
	STA $4017 ; (get), (put), (get), (put) : Reset the frame counter.
	LDA #$28  ; (get), (put)
	STA $4003 ; (get), (put), (get), (put) : Length = 4.
	LDA #$80  ; (get), (put)               : This upcoming write will clock it once, then we just need to wait for the second clock.
	STA $4017 ; (get), (put), (get), (put) : 5-step mode, disable IRQ (The CPU was on a "put" cycle when writing that, so the frame counter is reset in 3 CPU cycles.)
	LDA <$00  ; stall for 3 CPU cycles.
	; Okay, the third time the length counters get clocked is in 58213 CPU cycles.
	JSR ClockslideFromWord
	.word 58178 ; PAL 2A07: read one cycle before the next 58193-cycle half-frame clock
	NOP ; 12 cycles to go
	NOP ; 10 cycles to go
	NOP ; 8 cycles to go
	NOP ; 6 cycles to go
	LDA <$00 ; 3 cycle to go
	LDA $4015 ; the pulse channel should have stopped just before you read.
	BNE FAIL_FrameCounter5Step2

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_FrameCounter5Step2:
FAIL_DeltaModulationChannel:
	JMP FAIL_AndDisableAudioChannels
;;;;;;;;;;;;;;;;;

TEST_DeltaModulationChannel:
	; STATUS: UNVERIFIED [DMC][OPENBUS] PAL DMC rates are DOC-BACKED. Tests A-N run in their 2A07 forms: K reads the wrapped sample byte as an opcode fetched from open bus (negative controls: the probe 1 cycle early or 3 late fails); L-N use the load-DMA rule with two probe layouts each. The L-N key is derived, not measured on a 2A07: pending hardware.
	
	; Special thanks to blargg, as I am pretty much just going to copy the test they wrote in 2005.
	LDA #$00
	STA $4012 ; Sample address $C000.
	LDA #1
	STA $4013 ; length of #1 * 16 + 1 = 17 bytes.
	LDA #$0F
	STA $4010 ; Fastest sample rate.
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	;;; Test 1 [APU Delta Modulation Channel]: Verify the DMC works ;;;
	; In other words, if the DMC is playing audio, bit 4 of address $4015 will be set.
	LDA #$10
	STA $4015
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	LDA $4015	; the DMC should be playing by now.
	AND #$10
	BEQ FAIL_DeltaModulationChannel	; If bit 4 is not set, then fail the test.
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods

	LDA $4015	; the DMC should have stopped by now.
	AND #$10
	BNE FAIL_DeltaModulationChannel	; If bit 4 is still set, then fail the test.
	INC <ErrorCode
	
	;;; Test 2 [APU Delta Modulation Channel]: Restarting the DMC should re-load the sample length. ;;;
	LDA #$10
	STA $4015
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods ; as we have established, the DMC is now playing.
	LDA #$00
	STA $4015
	LDA #$10
	STA $4015	; Restart the DMC! (The sample length should be reset to 17)
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	LDA $4015	; the DMC should still be playing.
	AND #$10
	BEQ FAIL_DeltaModulationChannel	; If bit 4 is not set (the sample ended), then fail the test.
	JSR ClockslideFromWord
	.word 4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	LDA $4015	; the DMC should have stopped by now.
	AND #$10
	BNE FAIL_DeltaModulationChannel	; If bit 4 is still set, then fail the test.
	INC <ErrorCode

	;;; Test 3 [APU Delta Modulation Channel]: Writing $10 to $4015 should start playing a new sample if the previous one ended. ;;;
	LDA #$10
	STA $4015
	JSR ClockslideFromWord
	.word 8000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 20 periods;	; wait for sample to end.
	STA $4015	; write $10 to $4015 again.
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	LDA $4015	; the DMC should be playing.
	AND #$10
FAIL_DeltaModulationChannel_BEQ:
	BEQ FAIL_DeltaModulationChannel
	INC <ErrorCode
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	
	;;; Test 4 [APU Delta Modulation Channel]: Writing $10 to $4015 while a sample is currently playing shouldn't affect anything. ;;;
	; Keep in mind, in test 2 we disabled the DMC before writing $10, so the sample was no longer playing in that situation. We're not going to disable it in this test.
	LDA #$10
	STA $4015
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods ; as we have established, the DMC is now playing.
	STA $4015	; Write $10 to $4015 again, while the sample is still playing. Nothing changes, don't reload the length or anything.
	LDA $4015	; the DMC should still be playing.
	AND #$10
	BEQ FAIL_DeltaModulationChannel_BEQ
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	LDA $4015	; the DMC should have stopped by now.
	AND #$10
	BNE FAIL_DeltaModulationChannel2
	INC <ErrorCode
	
	;;; Test 5 [APU Delta Modulation Channel]: Writing $00 to $4015 will immediately stop the sample. ;;;
	LDA #$10
	STA $4015
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods ; as we have established, the DMC is now playing.
	LDA #0
	STA $4015	; Write $10 to $4015 again, while the sample is still playing. Nothing changes, don't reload the length or anything.
	LDA $4015	; the DMC should have stopped
	AND #$10
	BNE FAIL_DeltaModulationChannel2
	INC <ErrorCode

	;;; Test 6 [APU Delta Modulation Channel]: Writing to $4013 doesn't change the sample length of the currently playing sample. ;;;
	LDA #$10
	STA $4015	; start the sample.
	LDA #2
	STA $4013	; 33 byte sample.	
	JSR ClockslideFromWord
	.word 8000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 20 periods;
	LDA $4015	; the DMC should have stopped by now.
	AND #$10
	BNE FAIL_DeltaModulationChannel2
	; but now the length is 33.
	LDA #$10
	STA $4015
	LDA #1
	STA $4013	; set the sample size back to 17.
	JSR ClockslideFromWord
	.word 12000
	LDA $4015	; the DMC should still be playing.
	AND #$10
	BEQ FAIL_DeltaModulationChannel2
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	LDA $4015	; the DMC should have stopped by now.
	AND #$10
	BNE FAIL_DeltaModulationChannel2
	INC <ErrorCode

	;;; Test 7 [APU Delta Modulation Channel]: The DMC IRQ Flag should not be set when disabled. ;;;
	; Friendly reminder that in the prep before test 1, we run:
	; LDA #$0F
	; STA $4010
	; which, in addition to using the fastest sample rate, disables the DMC IRQ.
	LDA #$10
	STA $4015 ; start sample.
	JSR ClockslideFromWord
	.word 8000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 20 periods; ; wait for sample to end.
	LDA $4015 ; Bit 7 (which sets the Negative flag) is set if the DMC IRQ flag is set.
	BMI FAIL_DeltaModulationChannel2	; in this case, it should not be set.
	INC <ErrorCode

	;;; Test 8 [APU Delta Modulation Channel]: The DMC IRQ Flag should be set when enabled, and a sample ends. ;;;
	SEI			; prevent IRQs from actually interrupting the CPU.
	LDA #$8F	; enable the IRQ (and continue using the fastest rate)
	STA $4010
	LDA #$10
	STA $4015 ; start sample.
	JSR ClockslideFromWord
	.word 8000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 20 periods; ; wait for sample to end.
	LDA $4015 ; Bit 7 (which sets the Negative flag) is set if the DMC IRQ flag is set.
	BPL FAIL_DeltaModulationChannel2	; in this case, it should be set.
	INC <ErrorCode
	BNE FAIL_DeltaModulationChannelContinue ; branch around the fail condition.

FAIL_DeltaModulationChannel2:
	JMP FAIL_AndDisableAudioChannels

FAIL_DeltaModulationChannelContinue:
	;;; Test 9 [APU Delta Modulation Channel]: Reading $4015 does not clear the IRQ flag. ;;;
	LDA $4015 ; Bit 7 should still be set.
	BPL FAIL_DeltaModulationChannel2
	INC <ErrorCode

	;;; Test A [APU Delta Modulation Channel]: Writing to $4015 does clear the IRQ flag. ;;;
	LDA #$10  ; Demonstrated by writing $10, but writing a zero will also clear the IRQ flag.
	STA $4015
	LDA $4015
	BMI FAIL_DeltaModulationChannel2
	LDA #$0
	STA $4015
	INC <ErrorCode

	;;; Test B [APU Delta Modulation Channel]: Disabling the IRQ flag clears the IRQ flag. ;;;
	LDA #$10
	STA $4015 ; start sample.
	JSR ClockslideFromWord
	.word 8000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 20 periods; ; wait for sample to end.
	; As we have established in test 8, the IRQ flag is currently enabled.
	LDA #$0F
	STA $4010	; disable the IRQ flag.
	LDA $4015
	BMI FAIL_DeltaModulationChannel2
	INC <ErrorCode

	;;; Test C [APU Delta Modulation Channel]: Looping samples should loop. ;;;
	; In other words, bit 4 of address $4015 will be set until you force the sample to stop.
	LDA #$4F	; loop! (and the fastest sample rate)
	STA $4010
	LDA #$10
	STA $4015
	JSR Clockslide_50000 ; wait for a fairly long amount of time.
	LDA $4015
	AND #$10
	BEQ FAIL_DeltaModulationChannel2 ; it should still be playing, since it loops.
	LDA #$00
	STA $4015	; stopping the DMC should still stop the looping sample.
	; You might fail this test if you are waiting 2 or 3 CPU cycles to disable the DMC Channel.
	LDA $4015
	AND #$10
	BNE FAIL_DeltaModulationChannel2
	INC <ErrorCode

	;;; Test D [APU Delta Modulation Channel]: Looping samples should not set the IRQ flag when they loop. ;;;
	LDA #$CF	; loop + enable IRQ flag! (and the fastest sample rate)
	STA $4010
	LDA #$10
	STA $4015
	JSR Clockslide_50000 ; wait for a fairly long amount of time.
	LDA $4015
	BMI FAIL_DeltaModulationChannel2 ; The IRQ flag is not set on looping samples.
	STA $4015
	LDA $4015	; Even if the sample is force-stopped, the IRQ flag is not set.
	BMI FAIL_DeltaModulationChannel2
	INC <ErrorCode

	; The 26352-cycle waits below are DMC sample-position waits in CPU cycles,
	; PAL frame waits. The 2A07 DMC timer period is expressed in CPU cycles.
	;;; Test E [APU Delta Modulation Channel]: Clearing the looping flag and then setting it again should keep the sample looping. ;;;
	LDA #$10
	STA $4015
	JSR ClockslideFromWord
	.word 24400 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 61 periods
	LDA #$8F	; Disable loop
	STA $4010
	LDA #$CF
	STA $4010	; enable loop again
	JSR Clockslide_50000 ; wait for a fairly long amount of time.
	LDA $4015
	AND #$10
	BEQ FAIL_DeltaModulationChannel3 ; it should still be playing.
	LDA #$00
	STA $4015
	INC <ErrorCode

	;;; Test F [APU Delta Modulation Channel]: Clearing the looping flag will not immediately end the sample. The sample will then play for it's remaining bytes. ;;;
	LDA #$10
	STA $4015
	JSR ClockslideFromWord
	.word 24400 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 61 periods
	LDA #$8F	; Disable loop
	STA $4010
	LDA $4015
	BMI FAIL_DeltaModulationChannel3 ; The IRQ flag should not have been set.
	AND #$10
	BEQ FAIL_DeltaModulationChannel3 ; it should still be playing.
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	LDA $4015	; the DMC should have stopped by now.
	BPL FAIL_DeltaModulationChannel3 ; The IRQ flag should have been set.
	AND #$10
	BNE FAIL_DeltaModulationChannel3
	INC <ErrorCode

	;;; Test G [APU Delta Modulation Channel]: A looping sample will re-load the sample length from $4013 every time the sample loops. ;;;
	LDA #$CF	; loop + enable IRQ flag! (and the fastest sample rate)
	STA $4010
	LDA #$10
	STA $4015
	JSR ClockslideFromWord
	.word 24400 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 61 periods
	LDA #02
	STA $4013	; sample length is now 33.
	LDA #$8F	; disable the loop
	STA $4010
	LDA $4015
	BMI FAIL_DeltaModulationChannel3 ; The IRQ flag should not have been set.
	AND #$10
	BEQ FAIL_DeltaModulationChannel3 ; it should still be playing.
	JSR Clockslide_4000 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 10 periods
	LDA $4015	; the DMC should have stopped by now.
	BPL FAIL_DeltaModulationChannel3 ; The IRQ flag should have been set.
	AND #$10
	BNE FAIL_DeltaModulationChannel3
	INC <ErrorCode
	BNE FAIL_DeltaModulationChannelC2 ; branch around another fail condition.

FAIL_DeltaModulationChannel3:
	JMP FAIL_AndDisableAudioChannels
;;;;;;;;;;;;;;;;;
	
FAIL_DeltaModulationChannelC2:
	;;; Test H [APU Delta Modulation Channel]: Writing $00 to $4013 should result in the following sample being 1 byte long. ;;;
	LDA #$0F	; disable IRQ and loop.
	STA $4010
	LDA #0
	STA $4013 ; 1-byte sample.
	LDA #$10
	STA $4015
	JSR ClockslideFromWord
	.word 1600 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 4 periods
	LDA $4015	; the DMC should have stopped by now.
	AND #$10
	BNE FAIL_DeltaModulationChannel3
	INC <ErrorCode

	;;; Test I [APU Delta Modulation Channel]: There should be a one-byte buffer that's filled immediately if empty. ;;;
	LDA #$8F
	STA $4010 ; enable IRQ flag, fastest speed.
	LDA #1
	STA $4013 ; 17 byte sample.
	LDA #$10
	STA $4015 ; enable the DMC
	LDA #$10
TEST_DeltaModulationChannelTestILoop:
	AND $4015 ; Loop until the sample ends.
	BNE TEST_DeltaModulationChannelTestILoop
	JSR ClockslideFromWord
	.word 1630 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 4 periods + 30
	LDA #0
	STA $4013 ; 1 byte sample.
	LDA #$10
	STA $4015 ; Enable DMC
	; On a 2A07 the load DMA can only land on an opcode fetch (NESdev forum "PAL DMA behavior", RP2A07 traces), and
	; this LDA's own fetch comes 1 cycle after the write, before the DMA is requested. Two NOPs give it opcode fetches 1,
	; 3 and 5 cycles after the write (the LDA's being the last), so "filled immediately" (within a few cycles, not at the
	; next 400-cycle output cycle) is still what is tested; the exact request delay after a $4015 write is not documented
	; for the 2A07 and does not matter here.
	NOP
	NOP
	LDA $4015 ; Immediately read from $4015: (There's a 50% chance the DMA occurs when the address bus is pointing to $4015. That doesn't change anything though.)
	AND #$90  ; The IRQ flag should be set, and the sample should have ended.
	CMP #$80
	BNE FAIL_DeltaModulationChannel3
	LDA #$10
	STA $4015 ; we go again.
	LDA $4015	
	BEQ FAIL_DeltaModulationChannel3
	; at this point we are playing audio.
	JSR ClockslideFromWord
	.word 1600 ; rate $F period 400 on the 2A07 (NESdev "APU DMC" PAL rate table): 4 periods
	; and now we aren't
	LDA $4015	
	AND #$10
	BNE FAIL_DeltaModulationChannel3
	INC <ErrorCode
	; Thanks again to blargg for those tests!
	
	;;; Test J [APU Delta Modulation Channel]: Check that the DMASync_50CyclesRemaining function works in this emulator ;;;	
	; 2A07 form (open-bus opcode probe, see TEST_DMA_Plus_OpenBus): the DMA has to land exactly on the $4000 fetch.
	LDA #LOW(TEST_DeltaModulationChannel_JRet)
	LDX #HIGH(TEST_DeltaModulationChannel_JRet)
	JSR TEST_OBProbe_Install
	JSR DMASync_50CyclesRemaining
	JSR Clockslide_34                ; 34
	LDA #HIGH(TEST_DeltaModulationChannel_JRet) ; 36
	PHA                              ; 39
	LDA #LOW(TEST_DeltaModulationChannel_JRet) ; 41
	PHA                              ; 44
	PHP                              ; 47
	JMP $4000                        ; $4000 fetch at 50 = the DMA's request point
TEST_DeltaModulationChannel_JRet:
	LDA <$50
	BNE TEST_DeltaModulationChannel_JPass
	JMP FAIL_DeltaModulationChannel3   ; (out of branch range)
TEST_DeltaModulationChannel_JPass:
	INC <ErrorCode

	;;; Test K [APU Delta Modulation Channel]: Check that that Sample Address overflows to $8000 instead of $0000 ;;;
	; 2A07 form. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA behavior", t=25939), so the byte a DMA
	; reads can only be seen as an opcode fetched from open bus (see TEST_DMA_Plus_OpenBus), never by LDA $4000.
	; The sample is 225 bytes from $FFC0 ($4013 = 14): bytes 1-64 come from $FFC0-$FFFF, and byte 225 comes from $80A0 if
	; the address wraps to $8000, or from $00A0 if it wrongly wraps to $0000. This build holds $00 at $80A0 (checked at run
	; time below), so the right wrap turns the probe's opcode into BRK (hit). RAM $A0 is set to $40 for the test, so the
	; wrong wrap gives RTI, the same as no DMA at all (miss).
	; Timing (rate $F, one byte every 400 cycles; R(k) = request k, R(0) is the sync's DMA 50 cycles after the sync returns):
	; a reload DMA is requested on a put cycle and halts on the first opcode fetch at or after it; 4 cycles if that fetch is
	; a put. Each pass of the loop is 396 cycles with its NOP fetched exactly on R(k), so the CPU resumes on R(k)+4 and the
	; next NOP is fetched on R(k+1). Requests 0-223 land on the NOP, 224 on the JSR after the loop, 225 (byte 225) on $4000.
	LDA $80A0                         ; the key byte. If a later edit moves it, this subtest fails instead of passing blind.
	BEQ TEST_DMC_K_KeyOK
	JMP FAIL_DeltaModulationChannel4
TEST_DMC_K_KeyOK:
	LDA <$A0                          ; suiteExecPointerList's first byte: saved, restored after the probe.
	STA <$6F
	LDA #$40
	STA <$A0                          ; a wrap to $0000 would fetch this RTI: no hit.
	LDA #LOW(TEST_DMC_K_Ret)
	LDX #HIGH(TEST_DMC_K_Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DMC_K_Ret
	JSR DMASync_50CyclesRemaining
	LDA #14		;+2
	STA $4013	;+4 sample length = 14 * 16 + 1 = 225
	LDA #$FF	;+2
	STA $4012	;+4 Sample address is $FFC0
	LDA #$4F	;+2
	STA $4010	;+4 fastest rate. (also loop, so R(0) reloads the address and length)
	LDX #$0		;+2
	JSR Clockslide_30                 ; 50: R(0) falls on the next opcode fetch.
TEST_DMC_OverflowLoop: ; one pass = 396 cycles + the DMA's 4 = one rate-$F period.
	NOP                               ; +2  fetched on R(k): the DMA halts here (a put, 4 cycles) and the fetch is repeated.
	JSR ClockslideFromWord
	.word 387
	INX                               ; +2
	CPX #224                          ; +2
	BNE TEST_DMC_OverflowLoop         ; +3 if looping, +2 if not: the loop is left on R(224)-1.
	LDA <$00                          ; +3  fetched on R(224)-1, ends on R(224)+1.
	JSR ClockslideFromWord            ; fetched on R(224)+2: the DMA halts here (a put, 4 cycles); the CPU resumes on R(224)+6.
	.word 378                         ; -> R(224)+384
	LDA #HIGH(TEST_DMC_K_Ret)         ; +2
	PHA                               ; +3
	LDA #LOW(TEST_DMC_K_Ret)          ; +2
	PHA                               ; +3
	PHP                               ; +3
	JMP $4000                         ; +3: $4000 is fetched on R(224)+400 = R(225), the DMA that reads byte 225.
TEST_DMC_K_Ret:
	LDA <$6F
	STA <$A0                          ; restore suiteExecPointerList.
	LDA #0
	STA $4015                         ; stop the looping sample.
	LDA <$50
	BNE TEST_DMC_K_Pass
	JMP FAIL_DeltaModulationChannel4
TEST_DMC_K_Pass:
	INC <ErrorCode

	;;; Test L [APU Delta Modulation Channel]: (2A07) Enabling the DMC 2 cycles before the sample buffer empties gives a DMA timed from the $4015 write. ;;;
	; 2A07 form of tests L, M and N. The 2A03 statement is "the DMA is delayed 1, 2 or 3 cycles when the $4015 write
	; comes 2, 1 or 0 cycles before the buffer empties", measured there by the DMA's length through an open-bus data read.
	; Derived for the 2A07 from the load-DMA rule (Fiskbit, NESdev forum "DMC DMA incorrect timing?", t=26827): the DMA first
	; tries to halt on the 3rd cycle after a $4015 write on a put cycle, on the 4th after a write on a get cycle, and on a
	; 2A07 it then waits for an opcode fetch. The buffer empties on a put cycle E (where the reload DMA would be requested):
	;   L: write on E-2 (put), first try on the 3rd cycle after the write.
	;   M: write on E-1 (get), first try on the 4th cycle after the write.
	;   N: write on E   (put), first try on the 3rd cycle after the write.
	; TEST_DMC_LoadProbe runs one of two layouts after the write (w):
	;   A: NOP (fetch w+1), JMP $4000 (fetch w+3), $4000 fetched on w+6: hit when the first try is on w+4, w+5 or w+6.
	;   B: JMP $4000 (fetch w+1), $4000 fetched on w+4:                 hit when the first try is on w+2, w+3 or w+4.
	; Expected (A, B): L = miss, hit. M = hit, hit (only a first try on w+4 gives both). N = miss, hit.
	; A DMA requested when the buffer empties instead (E) would land on the fetch on w+1 in M and N: both fail.
	; The key is derived, not measured on a 2A07: pending hardware.
	LDX #0
	LDY #0
	JSR TEST_DMC_LoadProbe
	BNE FAIL_DeltaModulationChannel4
	LDX #0
	LDY #1
	JSR TEST_DMC_LoadProbe
	BEQ FAIL_DeltaModulationChannel4
	INC <ErrorCode

	;;; Test M [APU Delta Modulation Channel]: (2A07) Enabling the DMC 1 cycle before the sample buffer empties: first try on the 4th cycle after the write. ;;;
	LDX #1
	LDY #0
	JSR TEST_DMC_LoadProbe
	BEQ FAIL_DeltaModulationChannel4
	LDX #1
	LDY #1
	JSR TEST_DMC_LoadProbe
	BEQ FAIL_DeltaModulationChannel4
	INC <ErrorCode
	BNE FAIL_DeltaModulationChannelC3
FAIL_DeltaModulationChannel4:
	JMP FAIL_AndDisableAudioChannels
FAIL_DeltaModulationChannelC3:

	;;; Test N [APU Delta Modulation Channel]: (2A07) Enabling the DMC on the cycle the sample buffer empties: first try on the 3rd cycle after the write. ;;;
	LDX #2
	LDY #0
	JSR TEST_DMC_LoadProbe
	BNE FAIL_DeltaModulationChannel4
	LDX #2
	LDY #1
	JSR TEST_DMC_LoadProbe
	BEQ FAIL_DeltaModulationChannel4

	;; END OF TEST ;;
	LDA #$00
    STA $4015	; disable all audio channels.
	LDA #1
	RTS
;;;;;;;

TEST_DMC_LoadProbe:
	; In: X = 0, 1 or 2: the $4015 write lands 2 - X cycles before the sample buffer empties. Y = 0: layout A
	; (NOP, JMP $4000), otherwise layout B (JMP $4000). Out: A = <$50> (1 = the DMA landed on the $4000 fetch), Z set from it.
	; Cycles are counted from DMASync's return, 322 cycles before the point E where the buffer empties (see DMASyncWithoutOpenBus).
	STX <$52                          ; the variable delay n
	STY <$53                          ; the layout
	TYA
	BNE TEST_DMC_LP_NoAdjust
	INC <$52                          ; layout A's path through the BNE below is 1 cycle shorter: n + 1 makes up for it.
TEST_DMC_LP_NoAdjust:
	LDA #LOW(TEST_DMC_LP_Ret)
	LDX #HIGH(TEST_DMC_LP_Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DMC_LP_Ret
	JSR DMASync                       ; E is 322 cycles away.
	JSR Clockslide_200                ; 200
	JSR Clockslide_40                 ; 240
	LDA #0                            ; 242
	STA $4015                         ; 246  DMC off: bytes remaining = 0; the buffer still holds its byte until E.
	STA $4013                         ; 250  1-byte sample
	LDA #$0F                          ; 252
	STA $4010                         ; 256  rate $F, no loop, no IRQ
	LDA <$52                          ; 259
	JSR Clockslide37_Plus_A           ; 296 + n  (6 JSR + 23 + the slide's 8 + A, counted)
	LDA <$53                          ; 299 + n
	BNE TEST_DMC_LP_B                 ; 301 + n (A, n = X + 1) / 302 + n (B, n = X): both 302 + X
	LDA #HIGH(TEST_DMC_LP_Ret)        ; +2
	PHA                               ; +3
	LDA #LOW(TEST_DMC_LP_Ret)         ; +2
	PHA                               ; +3
	PHP                               ; +3   315 + X
	LDA #$10                          ; +2   317 + X
	STA $4015                         ; the write is this instruction's 4th cycle: w = 320 + X = E - 2 + X
	NOP                               ; fetch w+1
	JMP $4000                         ; fetch w+3; $4000 fetched on w+6
TEST_DMC_LP_B:
	LDA #HIGH(TEST_DMC_LP_Ret)
	PHA
	LDA #LOW(TEST_DMC_LP_Ret)
	PHA
	PHP
	LDA #$10
	STA $4015                         ; w = 320 + X = E - 2 + X
	JMP $4000                         ; fetch w+1; $4000 fetched on w+4
TEST_DMC_LP_Ret:
	LDA <$50
	RTS
;;;;;;;

TEST_VblankSync_PreTest:
	; This runs almost immediately after power on, in order to check if the VBlank Sync routine won't loop infinitely.
	LDA $2002
	BPL TEST_VblankSync_PreTest
	; We are now in VBlank, but there's a large window in which this could have occurred.
	; LDA [Read Opcode] [Read Operand] [Read Operand] * [Read $2002]
	; BPL [Read Opcode] [Read Operand] [Dummy Read, move PC]
	; A 7 CPU cycle window is a bit large.
	; At the moment we execute this code, all we know is that the VBlank flag was set between 3 and 10 CPU cycles ago.
	; The PAL VBlank flag is set near the end of the 33247.5-cycle frame.
	; With rendering disabled, every 33248 CPU cycles will "fall back" 1 PPU cycle.
	; The plan: read $2002 shortly before the next PAL VBlank,
	; then stall for one PAL frame and read $2002 again.
	; This will take a minimum of 3 frames to exit, and a maximum of 24 frames.
	; If it takes longer than 24 frames, it can be assumed the frame timing has the wrong number of CPU/PPU cycles, and could never use my VBlank sync routines.
	LDX #0 ; +2 cycles.
	JSR ClockslideFromWord
	.word 33233
TEST_VblSyncPreTest_Loop:
	LDA $2002	;+3 [VBlank happens here?] +1
	BMI TEST_VblSyncPreTest_GoodEnding; +2
	INX; +2
	CPX #25 ; +2
	BEQ TEST_VblSyncPreTest_BadEnding ; +2
	JSR ClockslideFromWord
	.word 33234
	JMP TEST_VblSyncPreTest_Loop;+3
	
TEST_VblSyncPreTest_GoodEnding:
	LDA #1
	STA <result_VblankSync_PreTest
	RTS
TEST_VblSyncPreTest_BadEnding:
	LDA #$80	; I use $80 so my VBL sync routine can start by running `LDA <result_VblankSync_PreTest` `BMI FAIL`
	STA <result_VblankSync_PreTest
	RTS
;;;;;;;

TEST_DMABusConflict:
	; STATUS: DERIVED [2A07] The 2C02/2A03 version catches each DMC DMA's byte on a data read of $4000 and compares 65
	; bytes with a key: with the 6502 address bus in $4000-$401F, the DMA's read of sample address S also reads the APU
	; register $4000 | (S & $1F) (NESdev "DMA", Register conflicts). A 2A07 DMA only halts on an opcode fetch, so here
	; the DMA is caught on an opcode fetch at $4000 (the open-bus probe): the halted CPU's address is $4000 and the
	; conflict happens the same way. The sample is the silent one at $FFC0 (all $00). Pending hardware.
	; Please don't press anything on controller 2 during this test. :)
	JSR ReadController1 ; strobe the controllers and read controller 1 eight times: it now returns 1 in bit 0.
	;;; Test 1 [DMC DMA Bus Conflicts]: A DMC DMA landing on an opcode fetch from open bus changes the opcode (DMA + Open Bus passes). ;;;
	JSR TEST_DMA_Plus_OpenBus
	CMP #1
	BNE TEST_DBC_Fail
	LDA #2
	STA <ErrorCode ; (TEST_DMA_Plus_OpenBus changed the error code)
	;;; Test 2 [DMC DMA Bus Conflicts]: The DMA that reads sample byte $FFD6 (low bits $16) also reads the controller: the opcode at $4000 is $01, not $00. ;;;
	; Without the conflict the fetched byte is the sample's $00 (BRK at $4000, return address $4002). With it, bits 0-4
	; come from the controller (bit 0 = 1) and bits 5-7 from the sample: $01, ORA ($01,X). Its operand is open bus ($01)
	; and X = 22, so it reads through the pointer at $17/$18, set to $06FF, which holds $00: BRK at $4002, return $4004.
	LDA <$17
	PHA
	LDA <$18
	PHA
	LDA #$FF
	STA <$17
	LDA #$06
	STA <$18
	LDA #0
	STA $6FF
	LDA #23-1
	JSR TEST_DBC_Run
	PLA
	STA <$18
	PLA
	STA <$17
	LDA <$5D
	CMP #$40
	BNE TEST_DBC_Fail
	LDA <$5C
	CMP #$04
	BNE TEST_DBC_Fail
	INC <ErrorCode
	;;; Test 3 [DMC DMA Bus Conflicts]: The DMA that reads sample byte $FFD5 (low bits $15) also reads $4015, clearing the frame interrupt flag. ;;;
	SEI
	LDA #$00
	STA $4017
	JSR Clockslide_PALFrameIRQ ; the frame interrupt flag is set now
	LDA #22-1
	JSR TEST_DBC_Run
	LDA <$5D
	CMP #$40
	BNE TEST_DBC_Fail
	LDA <$5C
	CMP #$02
	BNE TEST_DBC_Fail ; the opcode is the sample's $00 (a read of $4015 does not drive the data bus)
	LDA $4015
	AND #$40
	BNE TEST_DBC_Fail ; the flag is still set: the DMA did not read $4015
	;; END OF TEST ;;
	LDA #1
	RTS
TEST_DBC_Fail:
	LDA #0
	STA $4015
	JMP TEST_Fail

TEST_DBC_Run:
	; In: A = n-1. The DMC (rate $F, 33-byte looping sample at $FFC0) makes request n land on the opcode fetch at $4000;
	; requests 0 to n-2 land on a NOP in the loop, n-1 on the JSR after it (the timing of [Delta Modulation Channel]
	; test K). Request n reads sample byte n-1. Out: <$5C>/<$5D> = the return address a BRK pushed ($0000 = none).
	STA <$5B ; the loop handles requests 0 to n-2
	LDA #0
	STA <$5C
	STA <$5D
	LDA #$4C
	STA $600
	LDA #LOW(TEST_DBC_BRK)
	STA $601
	LDA #HIGH(TEST_DBC_BRK)
	STA $602
	TSX
	STX <$5A
	JSR DMASync_50CyclesRemaining
	LDA #2		;+2
	STA $4013	;+4 sample length = 2 * 16 + 1 = 33
	LDA #$FF	;+2
	STA $4012	;+4 Sample address is $FFC0
	LDA #$4F	;+2
	STA $4010	;+4 fastest rate, looping
	LDX #$0		;+2
	JSR Clockslide_30                 ; 50: R(0) falls on the next opcode fetch.
TEST_DBC_Loop: ; one pass = 396 cycles + the DMA's 4 = one rate-$F period.
	NOP
	JSR ClockslideFromWord
	.word 386
	INX                               ; +2
	CPX <$5B                          ; +3
	BNE TEST_DBC_Loop                 ; +3 if looping, +2 if not
	LDA <$00                          ; +3
	JSR ClockslideFromWord            ; the DMA of request n-1 halts here
	.word 378
	LDA #HIGH(TEST_DBC_Ret)           ; +2
	PHA                               ; +3
	LDA #LOW(TEST_DBC_Ret)            ; +2
	PHA                               ; +3
	PHP                               ; +3
	JMP $4000                         ; +3: $4000 is fetched on request n.
TEST_DBC_BRK:
	PLA ; flags
	PLA
	STA <$5C ; return address low
	PLA
	STA <$5D ; return address high
TEST_DBC_Ret:
	LDX <$5A
	TXS
	LDA #0
	STA $4015 ; stop the looping sample.
	RTS
;;;;;;;;;;;;;;;;;

TEST_ImpliedDummyRead_BRKed:; This is where the PC *should* go after reading an opcode from $4015 during this test.
	PLA
	AND #$10 ; Check if we ran a BRK or if this was an IRQ.
	BEQ TEST_ImpliedDummyReadIRQed ; (This is needed when verifying the dummy read of the RTI instruction.)
	PHA
	LDX <Copy_SP
	TXS
	INC <$60 ; Mark address $60 as 1, indicating that we ran a BRK.
	JMP TEST_ImpliedDummyRead_Post ; And jump back to where you should go.

TEST_ImpliedDummyReadIRQed:
	PLA
	PLA
	JMP TEST_ImpliedDummyRead_Post ; And jump back to where you should go.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	
TEST_ImpliedDummyRead_Check:
	; 2A07 form: no DMC DMA. (The 2A03 form used one DMA per opcode to put a byte on the bus for an opcode fetch in
	; open bus, with five differently timed routines.) In: A = the opcode to test. Out: A = 0 if it failed.
	;
	; The stack holds a program. LDA <$A7 is executed at $3FFE/$3FFF ($A5 from the PPU I/O latch, $A7 from the $2007 read
	; buffer; <$A7> = $68) and leaves $68 on the bus, so $4000 is fetched as PLA. Each PLA leaves the byte it pulls on the
	; bus, which is the next opcode: PLAs at $4000-$4013, and the last one pulls the opcode under test:
	;   $4013  PLA        pulls the opcode under test (its dummy read is $4014)
	;   $4014  (opcode)   its second cycle is a dummy read of $4015: that clears the frame interrupt flag
	;   $4015  the next opcode is read from $4015 itself. Bit 5 comes from the data bus, the rest from the APU status:
	;            flag cleared:     $00 BRK (bus bit 5 clear) or $20 JSR (bus bit 5 set)   -> pass
	;            flag still set:   $40 RTI                   or $60 RTS                   -> fail
	;          BRK goes to TEST_ImpliedDummyRead_BRKed, which sets <$60>. The JSR's operands are the controller ports
	;          ($4016: bit 0 set, the bus in bits 5-7; $4017: $00), so it lands on $0021, $0061, $00A1 or $00E1 in the
	;          cleared zero page: a BRK there too. RTI and RTS pull the frame pushed under the program and go to
	;          TEST_ImpliedDummyRead_Post with <$60> still 0.
	; The frame under the program depends on what the opcode does to the stack and the bus:
	;   bus bit 5 clear (ASL A, CLC, ... and RTI itself):  PCH, PCL of Post, P = $24      (for the RTI)
	;   bus bit 5 set (ROL A, SEC, ... and RTS itself):    PCH, PCL of Post - 1           (for the RTS)
	;   PLA / PLP: one more byte for them to pull, $00 / $04: bus bit 5 clear, then the RTI frame.
	;   PHA: pushes A = $48 (the PLA at $4013 loaded it): bus bit 5 clear; the RTI pulls that $48 as P, then Post.
	;   PHP: pushes P = $34 (bus bit 5 set); the RTS pulls $34 and the $06 pushed here: $0635, where a JMP to Post waits.
	;   BRK: needs none (the handler restores the stack pointer); it gets the RTI frame.
	; The frame interrupt flag is only cleared when a $4015 read is on a put cycle (test 2), so an OAM DMA fixes the
	; cycle parity (the first cycle after it is a get) and the code after it puts the dummy read on a put:
	;   LDA #$A5 (0-1), STA $2002 (2-5), JMP $3FFE (6-8), LDA <$A7 (9-11), 20 PLAs (12-91), the opcode's fetch (92)
	;   and its dummy read of $4015 on cycle 93: odd, a put.
	STA <$A5 ; Store the opcode you want to test.
	TSX
	STX <Copy_SP
	
	LDA #0
	STA <$60 ; address $60 will be a 1 if we executed a BRK, and a 0 if we executed an RTI
	JSR ReadController1 ; We need controller 1 to be fully clocked, and controller 2 unclocked.
	LDA #$68
	STA <$A7 ; the byte LDA <$A7 puts on the bus: PLA
	LDA #$4C
	STA $0635 ; where PHP's fail path lands (see above): JMP TEST_ImpliedDummyRead_Post
	LDA #LOW(TEST_ImpliedDummyRead_Post)
	STA $0636
	LDA #HIGH(TEST_ImpliedDummyRead_Post)
	STA $0637
	SEI
	LDA #0
	STA $4015 ; every channel off: $4015 reads nothing but the frame interrupt flag
	STA $4017 ; 4-step mode, IRQ enabled
	JSR Clockslide_PALFrameIRQ ; the frame interrupt flag is set now
	JSR WriteToPPUADDRWithByte
	.byte $2C, $00
	.byte $A7, $FF
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007 ; PPU read buffer = $A7

	LDA <$A5
	CMP #$08 ; PHP?
	BEQ TEST_ImpliedDummyRead_Frame_PHP
	CMP #$48 ; PHA?
	BEQ TEST_ImpliedDummyRead_Frame_PHA
	CMP #$28 ; PLP?
	BEQ TEST_ImpliedDummyRead_Frame_PLP
	CMP #$68 ; PLA?
	BEQ TEST_ImpliedDummyRead_Frame_PLA
	AND #$20 ; Is bit 5 set? That changes the value read from $4015.
	BNE TEST_ImpliedDummyRead_Frame_Bit5
	LDY #$24 ; the P for the RTI: I set
TEST_ImpliedDummyRead_Frame_RTI:
	LDA #HIGH(TEST_ImpliedDummyRead_Post)
	PHA
	LDA #LOW(TEST_ImpliedDummyRead_Post)
	PHA
	TYA
	PHA
	JMP TEST_ImpliedDummyRead_Launch
TEST_ImpliedDummyRead_Frame_PLA:
	LDA #HIGH(TEST_ImpliedDummyRead_Post)
	PHA
	LDA #LOW(TEST_ImpliedDummyRead_Post)
	PHA
	LDA #$24
	PHA
	LDA #$00 ; pulled by the PLA under test
	PHA
	JMP TEST_ImpliedDummyRead_Launch
TEST_ImpliedDummyRead_Frame_PLP:
	LDA #HIGH(TEST_ImpliedDummyRead_Post)
	PHA
	LDA #LOW(TEST_ImpliedDummyRead_Post)
	PHA
	LDA #$24
	PHA
	LDA #$04 ; pulled by the PLP under test: I stays set
	PHA
	JMP TEST_ImpliedDummyRead_Launch
TEST_ImpliedDummyRead_Frame_PHA:
	LDA #HIGH(TEST_ImpliedDummyRead_Post)
	PHA
	LDA #LOW(TEST_ImpliedDummyRead_Post)
	PHA
	JMP TEST_ImpliedDummyRead_Launch
TEST_ImpliedDummyRead_Frame_PHP:
	LDA #$06
	PHA
	JMP TEST_ImpliedDummyRead_Launch
TEST_ImpliedDummyRead_Frame_Bit5:
	LDA #HIGH(TEST_ImpliedDummyRead_Post-1)
	PHA
	LDA #LOW(TEST_ImpliedDummyRead_Post-1)
	PHA
TEST_ImpliedDummyRead_Launch:
	LDA #0
	STA <$21 ; where the JSR fetched from $4015 can land: BRKs, whatever the helper routines above left in zero page
	STA <$61
	STA <$A1
	STA <$E1
	TSX ; For the TXS test: the stack pointer the opcode under test will see.
	LDA <$A5
	PHA ; the opcode under test: the last pull
	LDA #$68
	LDY #19
TEST_ImpliedDummyRead_Push:
	PHA ; 19 pulls of PLA
	DEY
	BNE TEST_ImpliedDummyRead_Push
	CLC ; PHP's fail path relies on the P it pushes: $34
	CLD
	CLV
	LDA #2
	STA $4014 ; OAM DMA (rendering is off): the next cycle is a get
	LDA #$A5  ; 0-1
	STA $2002 ; 2-5   PPU I/O latch = $A5: LDA zp at $3FFE
	JMP $3FFE ; 6-8

	NOP ; Some loops might jump a byte early in the event of failure.
TEST_ImpliedDummyRead_Post:

	LDA <$A5 ; Now we evaluate the results of the test. Real quick, BRK, RTI, JSR, and RTS don't actually move the PC away before the double-read from $4015, so let's read from $4015 to check if the dummy read occurred.
	BEQ TEST_ImpliedDummyRead_Eval_BRK_RTI_RTS
	CMP #$40 ; RTI?
	BEQ TEST_ImpliedDummyRead_Eval_BRK_RTI_RTS
	CMP #$60 ; RTS?
	BEQ TEST_ImpliedDummyRead_Eval_BRK_RTI_RTS
	; Okay cool. If not one of those, the BRK routine (only runs if the dummy read occurred) will write $01 to address $60.
	LDA <$60
	RTS

TEST_ImpliedDummyRead_Eval_BRK_RTI_RTS:
	LDA $4015  ; Check bit 6
	AND #$40
	EOR #$40 ; And flip this bit, so if it *was* a 1, then you fail.
	RTS
;;;;;;;

	
TEST_ImpliedDummyRead_BackupRAM:
	; Let's copy this value to somewhere that won't get overwritten.
	LDX #0
TEST_IDR_BackupRAM_loop:
	LDA <$00, X
	STA $700, X
	LDA #0
	STA <$00, X
	INX
	BNE TEST_IDR_BackupRAM_loop
	RTS
;;;;;;;
	
FAIL_ImpliedDummyRead:
	JSR TEST_ImpliedDummyRead_RestoreRAM
	JMP TEST_Fail
	
TEST_ImpliedDummyRead:
	; STATUS: 2A07 form, no DMC DMA anywhere in this test: the opcodes are put on the bus by PLAs running in open bus
	; (TEST_ImpliedDummyRead_Check). Every expectation is 6502 behaviour documented for the 2A03 and common to the 2A07.
	JSR TEST_ImpliedDummyRead_BackupRAM
	; Well, before the madness begins, let's make sure some pre-requisites are met.
	;;; Test 0 [Implied Dummy Reads]: SLO Absolute, X is properly emulated. ;;;
	; This is used to verify the timing that the Frame Counter Interrupt flag gets cleared.
	JSR TEST_SLO_1F
	LDX #0
	STX <ErrorCode
	CMP #1
	BNE FAIL_ImpliedDummyRead1
	INC <ErrorCode

	;;; Test 1 [Implied Dummy Reads]: Controller ports only have bit 0 and open bus. And maybe famicom microphone. ;;;
	; Confirm there's nothing odd going on with the controller ports.
	LDA $4016
	AND #$BA
	BNE FAIL_ImpliedDummyRead1
	LDA $4017
	AND #$BE
	BNE FAIL_ImpliedDummyRead1
	INC <ErrorCode

	;;; Test 2 [Implied Dummy Reads]: Prerequisite check. Does the frame counter interrupt flag get set if we enable it? ;;;
	LDA #0
	STA $4017
	JSR Clockslide_PALFrameIRQ ; [FRAME] DOC-BACKED over-wait: 33254-cycle 2A07 IRQ, 33298-cycle wait; not hardware-measured.
	LDA #0
	LDA $4015
	CMP #$40
	BNE FAIL_ImpliedDummyRead1
	; As a means of preventing these error codes from stretching beyond the alphabet, I'm going to also check for the get/put cycle behavior of clearing this flag under error code 2.
	; See [APU Frame Counter IRQ] test 6 and 7.
	LDA #$00	
	STA $4017	; 4-step mode, enable IRQ
	JSR Clockslide_PALFrameIRQ ; wait long enough that the IRQ flag would be set.
	JSR OAMDMAWithPage2 ; align with "get" cycle.
	LDA #0    ; (get), (put)
	LDX #0    ; (get), (put)
	.byte $1F	; (get) : SLO Absolute, X
	.word $4015 ; (put), (get), (put) : This reads from $4015 twice!
	BNE FAIL_ImpliedDummyRead1 ; If SLO is properly emulated, you might see bit 7 set here (failing the test). The flag is actually cleared before the second read, so it bit 7 should be 0.
	; This test *very deliberately* makes sure the double-reads from $4015 will always have bit 6 cleared before the second read, so we don't need to test for the alternate alignment here.

	INC <ErrorCode
	BNE TEST_ImpliedDummyReadPreReqContinue

FAIL_ImpliedDummyRead1:
	JMP FAIL_ImpliedDummyRead
;;;;;;;;;;;;;;;;;
TEST_ImpliedDummyReadPreReqContinue:
	;;; Test 3 [Implied Dummy Reads]: Prerequisite check. Does the PPU read buffer work? ;;;
	; This was "a modified version of DMA + Open Bus": the 2A03 form of this test put its opcodes on the bus with DMC
	; DMAs. The 2A07 form (see TEST_ImpliedDummyRead_Check) uses no DMA; it enters open bus through $3FFE/$3FFF, which
	; needs the PPU I/O latch (checked in test 4) and the $2007 read buffer (checked here). Rendering stays off from here.
	JSR WaitForVBlank
	JSR DisableRendering
	JSR WriteToPPUADDRWithByte
	.byte $2C, $00
	.byte $A7, $FF
	JSR ReadPPUADDRFromWord
	.byte $2C, $00
	CMP #$A7
	BNE FAIL_ImpliedDummyRead1
	JSR ResetScroll
	INC <ErrorCode
	
	;;; Test 4 [Implied Dummy Reads]: Prerequisite check. Is open bus accurate enough for this test? ;;;
	; This test actually does work on an everdrive (and it would be nice not to fail because of unrelated open bus issues.)
	; ... we pretty much just need to verify that open bus from $4000 to $401F is good, and if address $4015 updates the data bus or not.
	LDA #$5A
	STA $2002	; ppu bus is now $5A
	LDX #$10
	LDA $3FF0, X	; Read ppu bus, read open bus. (this works on an everdrive too.)
	CMP #$5A
	BNE FAIL_ImpliedDummyRead1
	; We already confirmed SLO Absolute, X is accurate, so...
	LDA #0
	LDX #3
	.byte $1F
	.word $4015 ; SLO $4015, X
	; despite the first read being from $4015, the data bus won't be updated. The second read is from $4018, which will read #$40.
	; Then it gets SLO'd to be $80
	CMP #$80
	BNE FAIL_ImpliedDummyRead1
	LDA #$20
	STA $2002
	LDX #$25
	LDA $3FF0, X
	AND #$20
	BEQ FAIL_ImpliedDummyRead1
	
	
	; Check the open bus bits of the controller port.
	JSR WaitForVBlank
	LDA #$F0
	STA $2002	; Set the PPU IO bus to $F0
	LDX #$17
	LDA $3FFF, X ; dummy read $2006. (The data bus is now $F0) The offset moves the address bus to $4016, reading from controller 1 when the data bus was $F0.
	AND #$E0
	CMP #$E0 ; The open bus bits are all set.
	BNE FAIL_ImpliedDummyRead1
	LDA #$FF
	JSR SetPPUReadBufferToA
	LDX #$18
	LDA $3FFF, X ; dummy read $2007 (The data bus is now $F0) The offset moves the address bus to $4017, reading from controller 1 when the data bus was $F0.
	PHA
	JSR ResetScroll	; And reset the scroll, since we just moved "v" to $2400.
	PLA
	AND #$E0
	CMP #$E0 ; The open bus bits are all set.
	BEQ TEST_IDR_OpenBusBitsOK
	JMP FAIL_ImpliedDummyRead
TEST_IDR_OpenBusBitsOK:
	
	; This next pre-requisite doesn't have an error code, because I assume the emulator will crash if it gets this wrong.
	; This is something you would have fixed if you pass the [Open Bus] test.

	; JSR works like this. (simplified)
	;	Read Opcode
	;	Read Operand
	;	Dummy read from the stack.
	;	Push PCH
	;	Push PCL
	;	Read Operand
	;
	; And yes, pushing to the stack updates the data bus.
	;
	; This is another test that would have been verified if I just ran the full [Open Bus] test, but you know... I really want the everdrive to be able to run this test.
	;
	; So we're going to JSR to open bus, and then RTS. And if we fail the test, it will probably crash or something. I don't know.
	; It's not really possible to know how an emulator would act if they got the order of operations wrong here. Something other than the 2nd operand would be on the data bus.
	; 2A07 form of this prerequisite (the 2A03 form ran JSR $4000 with a DMC DMA supplying an RTS). No DMA: a program on the stack (see TEST_ImpliedDummyRead_Check) puts a JSR at $4010.
	;   LDA <$00 at $3FFE/$3FFF ($A5 from the PPU I/O latch, $00 from the read buffer; <$00> = $68) leaves PLA on the bus;
	;   PLAs at $4000-$400F, the last one pulls $20: JSR at $4010.
	;   JSR: [opcode $20] [low operand at $4011: open bus, $20] [stack] [push PCH $40] [push PCL $12]
	;        [high operand at $4012: open bus, which now holds the pushed PCL: $12]  ->  $1220, a mirror of RAM $0220,
	;        where a JMP to TEST_IDR_JSR_OK waits.
	;   A CPU that reads the high operand before the pushes gets $20: $2020, a mirror of $2000, which reads the PPU I/O
	;   latch. The $2007 read at $3FFF left $00 there: BRK, caught below.
	LDA #$4C
	STA $0220
	LDA #LOW(TEST_IDR_JSR_OK)
	STA $0221
	LDA #HIGH(TEST_IDR_JSR_OK)
	STA $0222                 ; $0220: JMP TEST_IDR_JSR_OK
	LDA #$4C
	STA $600
	LDA #LOW(TEST_IDR_JSR_Bad)
	STA $601
	LDA #HIGH(TEST_IDR_JSR_Bad)
	STA $602                  ; the BRK/IRQ vector's RAM stub: JMP TEST_IDR_JSR_Bad
	JSR WriteToPPUADDRWithByte
	.byte $2C, $00, $00
	.byte $FF
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007                 ; PPU read buffer = $00
	LDA #$68
	STA <$00                  ; the byte LDA <$00 puts on the bus: PLA (set after the two calls above, which use <$00/$01>)
	SEI
	TSX
	STX <Copy_SP
	LDA #$20
	PHA                       ; the last pull: JSR
	LDA #$68
	LDY #15
TEST_IDR_JSR_Push:
	PHA                       ; 15 pulls of PLA
	DEY
	BNE TEST_IDR_JSR_Push
	LDA #$A5
	STA $2002                 ; PPU I/O latch = $A5: LDA zp at $3FFE
	JMP $3FFE
TEST_IDR_JSR_Bad:
	LDX <Copy_SP
	TXS
	JSR ResetScroll
	JMP FAIL_ImpliedDummyRead
TEST_IDR_JSR_OK:
	LDX <Copy_SP
	TXS
	JSR ResetScroll           ; the PPU address was moved by the buffer set-up
	
	; And that should be all the pre-requisites.
	INC <ErrorCode

	;;; Test 5 through X [Implied Dummy Reads]: Do the implied instructions have dummy reads? (They should) ;;;
	; This test extends to every error code after this.
	
	; What are we testing for here?
	; The Implied Addressing mode instructions (NOP, ASL A, INX...) all have dummy reads on their second CPU cycle, reading from wherever the PC is.
	; So for instance, a NOP at address $8000 will dummy-read from address $8001. (since the PC is incremented before the second cycle)
	; pretty simple stuff, right?
	;
	; I suggest leaving it at that. You know what this test is checking for. Go forth and make those dummy reads. 
	; Trying to understand the following code is not necessary, and will drive you to madness.
	;
	; Do you even dare know how one tests for this?
	;
	; Abandon hope all ye who enter here.
	; This is without exaggeration, the most insane assembly code I have ever written.	
	
	; The idea:
	; Dummy read a read-sensitive register.
	;
	; Issue: The PPU registers have clock-alignment specific behavior changes, making the test too inconsistent. So we need to rely on the APU registers.
	;
	; The Idea take 2:
	; Dummy read $4015 to clear the Frame Counter Interrupt Flag, which will be clear when reading the next opcode.
	;
	; Issues:
	; Preparing an entire function to run inside open bus (setting up the opcode to be the instruction we want on the address we want to test) is not easy.
	; I need to sync a DMA while keeping the Frame Counter Interrupt Flag set. This DMA is used to change the data bus on the cycle after jumping to Open Bus.
	; The Frame Counter Interrupt Flag is only cleared when transitioning from a put cycle to a get cycle. (see [Frame Counter IRQ] test 6 and 7.)
	; When reading from $4015 as the opcode, bit 5 will be set if the opcode we tested had bit 5 set.
	; So making the Pass/Fail translate to a BRK/RTI will only work for half the instructions. The rest will be JSR/RTS.
	; I would *really* like it if this test did not crash in the event of failure, so I actually do need to make sure both cases are managed.
	; This means I need to manage a bunch of BRK, RTI, JSR, and RTS's, while making sure the stack pointer stays sane in the event of passing or failure.
	; If a JSR happens, the controller ports will be the operands. 
	; The controller ports have open bus in the upper 3 bits (controller 1 has 5 bits on famicom), which will leech off the value read from the opcode. (reading $4015 doesn't update the data bus)
	
	
	; Let's set up the BRK routine.
	LDA #$4C
	STA $600
	LDA #LOW(TEST_ImpliedDummyRead_BRKed)
	STA $601
	LDA #HIGH(TEST_ImpliedDummyRead_BRKed)
	STA $602
		
	LDX #0
TEST_ImpliedDummyRead_Loop:
	; loop
	STX <Copy_X
	LDA TEST_ImpliedDummyRead_OpsToTest, X
	SEI
	JSR TEST_ImpliedDummyRead_Check	; This is where the test occurs, using the current value of the A register as the opcode to check the behavior of.
	BEQ FAIL_ImpliedDummyRead2
	INC <ErrorCode
	LDX <Copy_X
	INX
	CPX #29	; this loops tests 29 opcodes.
	BNE TEST_ImpliedDummyRead_Loop

	;;; Test Y [Implied Dummy Reads]: Does cycle 6 of an RTS instruction perform a dummy read? (it should) ;;;

	JSR DisableRendering

	; You know, while we're here, let's check cycle 6 of RTS too!
	; Compared to the rest of the error codes in this test, this one will be real easy.
	; 2A07 form: no DMC DMA. (The 2A03 form returned to $4000 and had a DMA put an RTS on the bus there.) The RTS
	; under test returns to $2008, so its 6th cycle is a dummy read of $2007: that returns the read buffer ($60) into
	; the PPU I/O latch and advances v. $2008 mirrors $2000, which reads the latch: $60, a second RTS, back to
	; TEST_ImpliedDummyRead_PostRTS. The latch is set to $60 beforehand as well, so a CPU without the dummy read
	; still returns (and fails on v below) instead of crashing.
	LDA #HIGH(TEST_ImpliedDummyRead_PostRTS-1)
	PHA
	LDA #LOW(TEST_ImpliedDummyRead_PostRTS-1)
	PHA
	LDA #$20
	PHA
	LDA #$07
	PHA
	JSR WriteToPPUADDRWithByte
	.byte $2C, $00, $60 ; $2C00 = $60 (the RTS)
	.byte $2C, $01, $01 ; $2C01 = $01 (what the read after the test must return)
	.byte $FF
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007 ; read buffer = $60, v = $2C01
	LDA #$60
	STA $2002 ; PPU I/O latch = $60
	RTS       ; to $2008, with a dummy read of $2007
	
TEST_ImpliedDummyRead_PostRTS:
	NOP
	; now we need to read from $2007 to see if the dummy read updated 'v'
	LDA $2007
	CMP #1
	BNE FAIL_ImpliedDummyRead2	
		
	JSR TEST_ImpliedDummyRead_RestoreRAM
	
	LDA #1
	RTS
;;;;;;;

FAIL_ImpliedDummyRead2:
	JMP FAIL_ImpliedDummyRead
	
TEST_ImpliedDummyRead_RestoreRAM:
	SEI
	LDA <ErrorCode
	PHA
	; Let's copy this value to somewhere that won't get overwritten.
	LDX #0
TEST_IDR_RestoreRAM_loop:
	LDA $700, X
	STA <$00, X
	INX
	BNE TEST_IDR_RestoreRAM_loop
	PLA
	STA <ErrorCode
	RTS
;;;;;;;
	
TEST_ImpliedDummyRead_OpsToTest:
	ASL A
	CLC
	LSR A
	CLI	; make sure no interrupts will happen, ha!
	DEY
	TXA
	TYA
	TXS
	INY
	DEX
	CLD
	ROL A
	SEC
	ROR A
	SEI
	TAY
	TAX
	CLV
	TSX
	INX
	SED
	NOP	
	PLP
	PLA
	PHP
	PHA	
	BRK
	RTI
	RTS
;;;;;;;
	
TEST_AddrMode_AbsIndex:
	;;; Test 1 [Absolute Indexed Wraparound]: Does LDA Absolute, X read from the expected address ;;;
	; Let's just start with crossing a page boundary, as I would be bewildered if an emulator could even make it this far without indexed LDAs working at all.
	LDA #$5A
	STA $680 ; Set up address $680
	LDX #$F0 ; Set up X
	LDA $590, X ; Read from address $680
	CMP #$5A ; Check if it was the correct address.
	BNE FAIL_AddrMode_AbsIndex
	INC <ErrorCode
	
	;;; Test 2 [Absolute Indexed Wraparound]: Wrapping around from address $FFFF to $0000 ;;;
	LDA #$5A
	STA <$50
	LDX #$51
	LDA $FFFF, X	; $FFFF + $51 = $0050
	CMP #$5A ; Check if it was the correct address.
	BNE FAIL_AddrMode_AbsIndex
	; Make sure it wasn't a fluke. (I don't know. You could somehow incorrectly implement a hypothetical address $10050, and it might just happen to hold $5A.)
	LDA #$A5
	STA <$50
	LDA $FFFF, X	; $FFFF + $51 = $0050
	CMP #$A5 ; Check if it was the correct address.
	BNE FAIL_AddrMode_AbsIndex
	INC <ErrorCode
	
	;;; Test 3 [Absolute Indexed Wraparound]: The same applies to indexing with Y ;;;
	LDY #$51
	LDA $FFFF, Y	; $FFFF + $51 = $0050
	CMP #$A5 ; Check if it was the correct address.
	BNE FAIL_AddrMode_AbsIndex
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_AddrMode_AbsIndex:
	JMP TEST_Fail

TEST_AddrMode_ZPgIndex:
	;;; Test 1 [Zero Page Indexed Wraparound]: Does LDA <ZeroPage, X read from the expected address ;;;
	LDA #$A5
	STA <$58	; We'll read from address $58 just to test if this instruction is working as expected, with no edge cases.
	LDX #8
	LDA #0
	LDA <$50, X ; read from address $58
	CMP #$A5	; compare with $A5
	BNE FAIL_AddrMode_ZPgIndex ; And fail the test if the expected value wasn't read.
	INC <ErrorCode

	;;; Test 2 [Zero Page Indexed Wraparound]: Indexing should always remain on the zero page. ;;;
	; For instance, suppose X = $20. LDA <$F0, X won't read from address $0110, rather, it will read from address $0010.
	STA <$00
	LDA #$5A
	STA $100
	LDX #1
	LDA <$FF, X
	CMP #$A5
	BNE FAIL_AddrMode_ZPgIndex
	INC <ErrorCode

	;;; Test 3 [Zero Page Indexed Wraparound]: This also applies to Zero Page with Y indexing. ;;;
	LDY #1
	LDX <$FF, Y
	CPX #$A5
	BNE FAIL_AddrMode_ZPgIndex
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_AddrMode_ZPgIndex
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_AddrMode_Indirect:
	;;; Test 1 [Indirect Addressing Wraparound]: Does JMP (indirect) move the program counter to the correct location? ;;;
	; I guess if it doesn't then the emulator would likely crash, huh?
	LDA #LOW(TEST_AddrMode_Indirect_Pass1)
	STA $500
	LDA #HIGH(TEST_AddrMode_Indirect_Pass1)
	STA $501
	LDX #0
	JMP [$0500]
	INX	; I don't know... I guess an emulator could just choose not to move the PC anywhere at all?
TEST_AddrMode_Indirect_Pass1:
	CPX #0
	BNE FAIL_AddrMode_Indirect
	INC <ErrorCode
	
	;;; Test 2 [Indirect Addressing Wraparound]: The Address bus wraps around the page when reading the low and high bytes with indirect addressing ;;;
	; Basically, if the indirect jump is at a page boundary, (address $5FF, for instance) the high byte will be read from the same page as the low byte.
	; So instead of reading $5FF and $600, it reads $5FF and $500.	
	LDY #0	; both X and Y are now zero.
	LDA #$60	; the opcode for RTS
	STA $580	; store at $580, where the upcoming indirect jump should move the PC.
	STA $681	; also store at 681. An incorrect emulation of the behavior tested here will move the PC to $680, where I will run INX, RTS.
	LDA #$E8	; the opcode for INX
	STA $680	; Store at $680, as mentioned above.
	; And now to set up the test.
	LDA #$80
	STA $5FF	; The low byte of the indirect jump is $80.
	LDA #5
	STA $500	; the correct indirect address is $580
	LDA #6
	STA $600	; while the incorrect address is $680
	JSR TEST_AddrMode_Indirect_Here ; RTS will move the PC back here after the test.
TEST_AddrMode_Indirect_Here: ; Yeah, this set up is a little cursed, but I wanted to use RTS at the locations in RAM instead of JMP.
	CPY #1
	BEQ TEST_AddrMode_Indirect_Next ; If this is executing after the RTS, this test won't need ran a second time.
	INY
	JMP [$05FF] ; If this jumps to $580, pass. if this jumps to $680, fail.	
TEST_AddrMode_Indirect_Next:
	CPX #01
	BEQ FAIL_AddrMode_Indirect
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;
	
FAIL_AddrMode_Indirect:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_AddrMode_IndIndeX:
	;;; Test 1 [Indirect Addressing, X Wraparound]: Does LDA (indirect, X) read from the expected address ;;;
	; Indirect addressing, X works like this:
	; The operand is a byte on the zero page. Add X to that address, the value of which will be the low byte of the target address of the instruction.
	; The following byte in memory will be the high byte of the target address.
	; For example, LDA ($50, X) would work like this: (Assume X = $10, address $60 has the value $00, and address $61 has the value $80)
	; Cycle 1: Read the opcode: $A1
	; Cycle 2: Read the operand: $50
	; Cycle 3: Dummy Read address $0050, and add X to this address.
	; Cycle 4: Read address $0060: $00
	; Cycle 5: Read address $0061: $80
	; Cycle 6: Read address $8000
	;
	; For my test, I'm going to start with something just as simple as that.
	; Address $580 will hold the value $5A
	LDA #$5A
	STA $580
	; and address $58 will be set up with a pointer to address $580
	LDA #$80
	STA <$58
	LDA #$05
	STA <$59
	; And now I set X to $08
	LDX #$08
	; And low we run the LDA instruction.
	LDA [$0050, X]
	; The result of which, should be the value at address $580
	CMP #$5A
	BNE FAIL_AddrMode_IndIndeX
	INC <ErrorCode

	;;; Test 2 [Indirect Addressing, X Wraparound]: The X indexing is confined to the zero page. ;;;
	; Set up $158 to point to address $680
	LDA #$80
	STA $158
	LDA #$06
	STA $159
	; Set X to $F0
	LDX #$F0
	; And low we run the LDA instruction.
	LDA [$0068, X]
	CMP #$5A
	BNE FAIL_AddrMode_IndIndeX
	INC <ErrorCode
	
	;;; Test 3 [Indirect Addressing, X Wraparound]: The Address bus wraps around the page when reading the low and high bytes with indirect addressing ;;;
	LDA #$80
	STA <$FF
	LDA #$05
	STA <$00
	LDA #$06
	STA $100
	; Set X to $00
	LDX #$00
	; And low we run the LDA instruction.
	LDA [$00FF, X]
	CMP #$5A
	BNE FAIL_AddrMode_IndIndeX
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_AddrMode_IndIndeX:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_AddrMode_IndIndeY:
	;;; Test 1 [Indirect Addressing, Y Wraparound]: Does LDA (indirect), Y read from the expected address ;;;
	; Indirect addressing, Y works like this:
	; The operand is a byte on the zero page, the value of which will be the low byte of the target address of the instruction.
	; The following byte in memory will be the high byte of the target address.
	; For example: LDA ($50), Y would work like this: (Assume Y= $20, address $50 has the value $F0, and address $51 has the value $80)
	; Cycle 1: Read the opcode: $B1
	; Cycle 2: Read the operand: $50
	; Cycle 3: Read address $0050: $F0
	; Cycle 4: Read address $0051: $80. Add Y to the low byte. The address bus is now pointing to $8010.
	; Cycle 5: Dummy Read address $8010. Fix the high byte of the address bus, since the Y indexing crossed a page boundary.
	; Cycle 6: Read from address $8110. (This cycle only occurs if the Y indexing crossed a page boundary.)
	;
	; For my test though, I'm just going to start with something simple.
	; Address $580 will hold the value $5A.
	LDA #$5A
	STA $580
	; and address $50 will be set up with a pointer to address $570
	LDA #$70
	STA <$50
	LDA #$05
	STA <$51
	; And now I set Y to $10
	LDY #$10
	; And low we run the LDA instruction.
	LDA [$0050], Y
	; The result of which, should be the value at address $580
	CMP #$5A
	BNE FAIL_AddrMode_IndIndeY
	INC <ErrorCode
	
	;;; Test 2 [Indirect Addressing, Y Wraparound]: The Y indexing is allowed to cross page boundaries. ;;;
	; Address $610 will hold the value $A5.
	LDA #$A5
	STA $610
	; and address $50 will be set up with a pointer to address $5F0
	LDA #$F0
	STA <$50
	LDA #$05
	STA <$51
	; And now I set Y to $20
	LDY #$20
	; And low we run the LDA instruction.
	LDA [$0050], Y
	; The result of which, should be the value at address $610
	CMP #$A5
	BNE FAIL_AddrMode_IndIndeY
	INC <ErrorCode
	
	;;; Test 3 [Indirect Addressing, Y Wraparound]: The Address bus wraps around the page when reading the low and high bytes with indirect addressing ;;;
	; LDA ($FF), Y works like this:
	; Cycle 1: Read the opcode: $B1
	; Cycle 2: Read the operand: $FF
	; Cycle 3: Read address $00FF:
	; Cycle 4: Read address $0000: (NOTE: This is NOT address $100. The high byte remains $00)
	; Cycle 5: etc.
	;
	; Address $610 will hold the value $5A.
	LDA #$5A
	STA $555
	; and address $FF will be set up with a pointer to address $555
	LDA #$55
	STA <$FF
	LDA #$05
	STA <$00
	; I also make sure address $100 is not #05
	LDA #$06
	STA $100 ; Address $655 should be $00, since that page gets cleared before hte test runs.
	; And now I set Y to $0
	LDY #$0
	; And low we run the LDA instruction.
	LDA [$00FF], Y
	; The result of which, should be the value at address $555, NOT the value at $655
	CMP #$5A
	BNE FAIL_AddrMode_IndIndeY	
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_AddrMode_IndIndeY:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_AddrMode_Relative:
	;;; Test 1 [Relative Addressing]: Branching from page $00 to page $FF ;;;
	LDA TEST_OpenBus_IRQRoutine,X ; Use the same routine as the [Open Bus] test IRQ. PLA 5 times, and JUMP to the fail condition.
	STA $600, X
	INX
	CPX #8
	BNE TEST_AddrMode_Relative	
	; Some emulators might implement this poorly, such that executing beyond address $FFFF crashes or maybe executes all zeroes? So let's set up the IRQ routine in case a BRK runs.
	; Let's first test by branching from the zero page. If the PC is somehow moving to a hypothetical Page -1, we could set up address $00 to be a BRK, in case it executes to it.
	LDA #$00
	STA <$00
	STA <$01
	STA <$02
	; Address $FFF9 has an RTS, so let's aim for there.
	LDA #$D0
	STA <$52
	LDA #$A5
	STA <$53
	JSR $0052	; This will branch to $FFF9, running an RTS. Otherwise, running a BRK.	
	INC <ErrorCode
	
	;;; Test 2 [Relative Addressing]: Branching from page $FF to page $00 ;;;
	LDA #$E6
	STA <$50
	LDA #$55
	STA <$51
	LDA #$80
	STA <$55
	JSR TEST_AddrMode_Relative_FFF5
	LDA <$55
	CMP #$81
	BNE FAIL_AddrMode_Relative
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_AddrMode_Relative:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_DecimalFlag:
	;;; Test 1 [The Decimal Flag]: The 6502 "Binary Coded Decimal" flag should not affect the ADC or SBC instructions on the NES ;;;
	; Despite the Decimal Flag existing, (BRK or PHP instructions will still set bit 3 of the value pushed depending on the state of this flag), it doesn't affect ADC or SBC.
	; So let's test that!
	SED
	; With the Decimal Flag set, we can run math, such as $55 - $16 = $39, despite the fact that that's not how hexadecimal numbers work.
	LDA #$55
	SEC
	SBC #$16
	; And if the decimal flag works, the result will be $39.
	; But remember, the decimal does NOT work on the NES. So the result should *actually* be the correct result of subtracting the two hexadecimal numbers, which is $3F.
	CMP #$3F
	BNE FAIL_DecimalFlag
	ADC #$16
	CMP #$56
	BNE FAIL_DecimalFlag
	INC <ErrorCode
	
	;;; Test 2 [The Decimal Flag]: Despite this flag not working, it still gets pushed in a PHP/BRK instruction ;;;
	PHP ; the decimal flag is set.
	PLA ; pull the processor stuff into the A register.
	AND #8 ; the Decimal flag is bit 3.
	BEQ FAIL_DecimalFlag
	CLD ; clear the decimal flag and do this again.
	PHP
	PLA
	AND #8
	BNE FAIL_DecimalFlag ; the Decimal flag is no longer set.
	; And that's pretty much it.
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_DecimalFlag:
	CLD
FAIL_BFlag:
	LDA #$40
	STA $4017
	JMP TEST_Fail

TEST_BFlag: 
	;;; Test 1 [The B Flag]: The "B flag" is set in the value pushed to the stack by by PHP ;;;
	PHP
	PLA
	STA <$50	; we'll get back to this one.
	AND #$10
	BEQ FAIL_BFlag
	INC <ErrorCode
	
	;;; Test 2 [The B Flag]: The "B flag" is set in the value pushed to the stack by by BRK ;;;
	; Set up the BRK routine
	LDA #$4C
	STA $600
	STA $700	; also set this up now for the NMI test.
	LDA #LOW(TEST_BFlag_BRK)
	STA $601
	LDA #HIGH(TEST_BFlag_BRK)
	STA $602
	BRK
TEST_BFlag_BRK:
	PLA ; pull off processor flags.
	STA <$51	; we'll get back to this one.
	PLA ; pull off the return address
	PLA ; ^
	LDA <$51
	AND #$10
	BEQ FAIL_BFlag ; the B flag should be set.
	INC <ErrorCode
	
	;;; Test 3 [The B Flag]: This emulator should be capable of running an IRQ before I run an IRQ test. ;;;
	LDA $4015 ; acknowledge any pending IRQs. (there shouldn't be one yet.)
	LDA #LOW(TEST_BFlag_BRK2)
	STA $601
	LDA #HIGH(TEST_BFlag_BRK2)
	STA $602
	SEI ; Set the interrupt flag to make sure the IRQ does not happen yet.
	LDA #0
	STA $4017 ; Set up the APU Frame Counter so an IRQ occurs in approximately 30,000 CPU cycles.
	JSR Clockslide_PALFrameIRQ ; stall for 30,000 CPU cycles.
	CLI ; Clear the interrupt flag, triggering the IRQ (after the first NOP. See [Interrupt Polling])
	NOP
	; The IRQ occurs here.
	NOP
	NOP
	SEI
	JMP TEST_Fail
	
TEST_BFlag_BRK2:
	LDA #$40
	STA $4017
	; this IRQ should set the interrupt flag, but better safe than sorry?
	SEI
	INC <ErrorCode
	
	;;; Test 4 [The B Flag]: The "B Flag" should not be set when processor flags get pushed by an IRQ ;;;
	PLA ; pull off processor flags.
	STA <$52	; we'll get back to this one.
	PLA ; pull off the return address
	PLA ; ^
	LDA <$52
	AND #$10
	BNE FAIL_BFlag ; the B flag should NOT be set.
	INC <ErrorCode
	
	;;; Test 5 [The B Flag]: The B Flag should not be set when processor flags get pushed by an NMI ;;;
	; we already set up $700 a while back.
	LDA #LOW(TEST_BFlag_NMI)
	STA $701
	LDA #HIGH(TEST_BFlag_NMI)
	STA $702
	JSR WaitForVBlank
	JSR Clockslide_20000
	JSR EnableNMI
TEST_BFlag_InfiniteLoop: ; just wait here for the NMI.
	JMP TEST_BFlag_InfiniteLoop ; if the NMI isn't implemented, then this test never could have even started, so don't worry about it.
TEST_BFlag_NMI:
	; this NMI should set the interrupt flag, but better safe than sorry?
	SEI
	JSR DisableNMI
	PLA ; pull off processor flags.
	STA <$53	; we'll get back to this one.
	PLA ; pull off the return address
	PLA ; ^
	LDA <$53
	AND #$10
	BNE FAIL_BFlag2 ; the B flag should NOT be set.
	INC <ErrorCode
	
	;;; Test 6, 7, 8, and 9 [The B Flag]: Bit 5 of the processor status is always set. ;;;
	LDX #0
TEST_BFlag_Bit5Loop:
	LDA <$50, X
	AND #$20
	BEQ FAIL_BFlag2
	INC <ErrorCode
	INX
	CPX #4
	BNE TEST_BFlag_Bit5Loop
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;
FAIL_BFlag2:
	LDA #$40
	STA $4017
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

FAIL_PPUReadBuffer:
	JSR ResetScroll
	JMP TEST_Fail
	
TEST_PPUReadBuffer:
	;;; Test 1 [PPU Read Buffer]: Reading from the PPU register at $2007 should work. ;;;
	; it is assumed that writing there works.
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA #$5A
	STA $2007
	STA $2007
	STA $2007
	
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA #0
	LDA $2007
	LDA $2007
	; this value should be $5A, even if the buffer isn't working.
	CMP #$5A
	BNE FAIL_PPUReadBuffer
	INC <ErrorCode
	
	;;; Test 2 [PPU Read Buffer]: Reading address $2007 should increment the "v" register. ;;;
	JSR ResetScrollAndWaitForVBlank
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA #$00	; write 00, 01, 02, and 03 to the nametable.
	STA $2007	; ^
	LDA #$01	; ^
	STA $2007	; ^
	LDA #$02	; ^
	STA $2007	; ^
	LDA #$03	; ^
	STA $2007	; ^
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007	; this should put 0 in the buffer
	LDA $2007	; this should read 0 from the buffer, and put 1 in the buffer.
	LDA $2007	; this should read 1 from the buffer, and put 2 in the buffer.
	BEQ FAIL_PPUReadBuffer
	INC <ErrorCode

	;;; Test 3 [PPU Read Buffer]: There should be a 1-byte buffer when reading from $2007 ;;;
	CMP #1
	BNE FAIL_PPUReadBuffer
	INC <ErrorCode

	;;; Test 4 [PPU Read Buffer]: Reading from CHR ROM should use the buffer. ;;;
	JSR ResetScrollAndWaitForVBlank
	JSR SetPPUADDRFromWord
	.byte $00, $00
	LDA $2007 ; prep buffer with 00
	LDA $2007 ; read $00
	LDA $2007 ; read $3C from CHR ROM.
	CMP #$3C
	BNE FAIL_PPUReadBuffer
	INC <ErrorCode
	
	;;; Test 5 [PPU Read Buffer]: Writing to $2006 does not modify the buffer value. ;;;
	JSR ResetScrollAndWaitForVBlank
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007 ; Prep buffer with 00
	LDA $2007 ; Prep buffer with 01
	LDA #$00
	STA $2006
	STA $2006 ; Move v to $0000
	LDA $2007 ; read the value of $01 from the buffer.
	CMP #$01
	BNE FAIL_PPUReadBuffer2
	INC <ErrorCode
	
	;;; Test 6 [PPU Read Buffer]: Reading from Palette RAM should NOT use the buffer. ;;;
	; However, pre revision G PPUs are unable to read from palette RAM, instead just reading from the nametable under that address.
	JSR ResetScrollAndWaitForVBlank
	JSR SetPPUADDRFromWord ; Let's check for pre-revision-g behavior by having a known value at this address.
	.byte $2F, $01
	LDA #$5A
	STA $2007
	JSR SetPPUADDRFromWord
	.byte $3F, $01
	LDA $2007 ; read $2D
	LDA $2007 ; read $30
	CMP #$5A
	BEQ PaletteRAM_PreRevisionG ; Pre revision G behavior detected!
	CMP #$30
	BNE FAIL_PPUReadBuffer2
	INC <ErrorCode
	
	;;; Test 7 [PPU Read Buffer]: The value on the nametable at $2700 through $27FF should be put in the buffer when reading from palette RAM at $3F00 through $3FFF. ;;;
	JSR ResetScrollAndWaitForVBlank
	JSR SetPPUADDRFromWord
	.byte $2F, $00
	LDA #$5A
	STA $2007	; VRAM $2700 = $5A
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007 ; Prep buffer with 00
	LDA $2007 ; Prep buffer with 01
	LDA $2007 ; Prep buffer with 02
	LDA #$3F
	STA $2006
	LDA #$00
	STA $2006 ; Move v to $3F00
	LDA $2007 ; read from palette RAM (buffer is now read from VRAM $2700 = $5A)
	LDA #$00
	STA $2006
	STA $2006 ; Move v to $0000
	LDA $2007 ; Read $5A from the buffer.	
	CMP #$5A
	BNE FAIL_PPUReadBuffer2

	;; END OF TEST ;;
	JSR ResetScroll
	LDA #$41 ; Success code "G", referring to a revision G (or later) PPU.
	RTS
;;;;;;;
	
FAIL_PPUReadBuffer2:
	JSR ResetScroll
	JMP TEST_Fail
	
PaletteRAM_PreRevisionG:
	; Revision G PPUs added the ability to read from Palette RAM.
	; In order to prevent Pre-Revision-G PPUs from "failing" the test, we exit early.
	; However, we will write on screen that we didn't actually finish the test.
	LDA <RunningAllTests
	BNE PaletteRAM_PreRevG_SkipMSG
	JSR Print_PreRevGBehavior
	JSR PrintTextCentered
	.word $2370
	.byte " Missing reads from Palette RAM.", $FF
PaletteRAM_PreRevG_SkipMSG:
	LDA #$39 ; Success code "E", referring to a pre revision G ppu.
	RTS
;;;;;;;

CycleClockBegin:
	JMP CycleClock2_Begin   ; The 2A07 cycle clock (see CycleClock2_Begin): no open-bus reads.
CycleClockEnd:
	JMP CycleClock2_End
CycleClock3_Exit:           ; The cycle clock's way back to CycleClockEnd's caller
	RTS
CheckDMATiming:             ; Calibrate the 2A07 cycle clock on an empty interval, then check that it measures
	LDA #0                  ; two NOPs as 4 cycles (Y = 4).
	STA $07E8
	JSR CycleClockBegin
	JSR CycleClockEnd       ; empty interval: its d is the reference
	LDA $07E9
	STA $07E8
	JSR CycleClockBegin     ; Imagine a stopwatch starting the moment this JSR instruction returns.
	NOP                     ; For this example, we'll make this four cycles long.
	NOP                     ; We stall for four cycles.
	JSR CycleClockEnd       ; Now imagine the stop watch halts the moment this JSR instruction begins.
CheckDMATiming_Fail:
	RTS                     ; Y holds the number of CPU cycles consumed by those two NOP instructions.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

FAIL_DMCDMAPlusOAMDMA:
	LDA #0
	STA $4015	; stop the DMC from playing.
	JMP TEST_Fail

TEST_DMCDMAPlusOAMDMA:
	; STATUS: 2A07 form. Test 1 (CheckDMATiming) is the 2A07 cycle clock. Test 2 measures the cycles stolen by an OAM DMA
	; and a DMC DMA with the open-bus opcode probe on the following DMC DMA (4 runs per position), against a key derived
	; from NESdev "DMA" (DMC DMA during OAM DMA) and the 2A07's fetch-only halting. Pending hardware.
	LDA <result_DMCDMASync_PreTest
	CMP #1
	BEQ TEST_DMCDMAPlusOAMDMA_PALGate
	CMP #2	; the DMA pre-test passed in its 2A07 form
	BNE FAIL_DMCDMAPlusOAMDMA	
TEST_DMCDMAPlusOAMDMA_PALGate:
	;;; Test 1 [DMC DMA + OAM DMA]: This test relies on precise DMA timing in order to calculate how many cycles the DMA took. Let's test for that now. ;;;
	; Let's confirm this DMA timing subroutine of mine works on this emulator.
	JSR CheckDMATiming
	STY <$50
	CPY #4 ; 
	BNE FAIL_DMCDMAPlusOAMDMA
	INC <ErrorCode

	; Okay, so what is this test actually testing for?
	; When the OAM DMA runs, the OAM DMA stalls the CPU.
	; When the OAM DMA is running and a DMC DMA also occurs:
	; The DMC DMA takes priority on get cycles, and the OAM DMA takes priority on put cycles. However, the OAM DMA will need to run an alignment cycle after the DMC DMA get.
	; However, if the DMC DMA is halted, the OAM DMA keeps going. This results in the DMC DMA appearing to only take 2 cycles.
	; It's also worth noting, that if the DMC DMA halt cycle occurs on the OAM DMA halt cycle, both halt cycles happen at the same time.
	; see https://www.nesdev.org/wiki/DMA#DMC_DMA_during_OAM_DMA
	;
	; 2A07 form. The 2A03 version measured with CalculateDMADuration, an open-bus data read loop that a 2A07 DMA
	; never reaches. Here the measurement is the open-bus opcode probe (TEST_OBProbe_Install) on the NEXT DMC DMA:
	;   - Rate $C (98 * 8 = 784 CPU cycles per byte, PAL table). R0 is the sync's DMA, R1 = R0 + 784 the DMA that meets
	;     the OAM DMA, R2 = R1 + 784 the DMA the probe looks for. Nothing else is stolen between R0 and R2.
	;   - The code from R0 to the probe's $4000 fetch has a fixed length, so that fetch is late by exactly the cycles the
	;     OAM DMA and R1 stole. Let c = stolen - 513. The probe hits when the fetch is 0, 1 or 2 cycles after R2
	;     (TEST_DMA_Plus_OpenBus). Four runs with the probe 0, 1, 2 and 3 cycles earlier hit for c = 0-2, 1-3, 2-4 and
	;     3-5: the four hits/misses give c (TEST_DOD_Decode).
	; KEY, derived (R1 is requested on a put cycle; W = the cycle of the $4014 write; all fetches around the write are
	; 2 cycles apart except inside STA $4014):
	;   Loop 1, R1 = W - 6 + X:
	;     R1 <= W-3: the DMA lands on the first opcode fetch at or after R1, 4 cycles on a put, 3 on a get; either way the
	;       write then falls on a get cycle and the OAM DMA takes 513: c = 4 when R1 is on a fetch (X = 1, 3), else 3.
	;     R1 = W-2 ... W: no opcode fetch until the one after the write, where both DMAs halt together; from W+1 on R1 is
	;       inside the OAM DMA. NESdev "DMA" (DMC DMA during OAM DMA): 2 extra cycles. The OAM DMA itself takes 513 after
	;       a write on a get (c = 2, odd X) and 514 after a write on a put (c = 3, even X).
	;   Loop 2, R1 = W + 504 + X; Lp = the OAM DMA's last put (W + 513 after a write on a get, W + 514 on a put):
	;     R1 <= Lp-4: 2 extra cycles. R1 = Lp-2 (second-to-last put): 1. R1 = Lp (last put): 3 (NESdev "DMA").
	;     R1 > Lp: the CPU is back on 2-cycle NOPs fetched on get cycles, so the DMA lands on a get: 3.
	;     c = that, plus 1 when the write was on a put (even X).
	; The during-OAM costs are the published 2A03 ones, assumed unchanged (the CPU stays halted on an opcode fetch during
	; the OAM DMA, so the 2A07's fetch-only halting does not get in the way). Pending hardware.
	; If you fail this test, look at $500-$50F (loop 1) and $510-$51F (loop 2) and compare with the answer key below.
	LDA #0
	STA <$5B                          ; loop 1
	TAX
TEST_DMCDMAPlusOAMDMA_Loop1:
	JSR TEST_DOD_Measure
	STA $500, X
	INX
	CPX #$10
	BNE TEST_DMCDMAPlusOAMDMA_Loop1
	INC <$5B                          ; loop 2
	LDX #0
TEST_DMCDMAPlusOAMDMA_Loop2:
	JSR TEST_DOD_Measure
	STA $510, X
	INX
	CPX #$10
	BNE TEST_DMCDMAPlusOAMDMA_Loop2
	LDA #0
	STA $4015                         ; stop the looping sample.

	;;; Test 2 [DMC DMA + OAM DMA]: Compare results with answer key ;;;
	LDX #0
TEST_DMCDMAPlusOAMDMA_Loop3:
	LDA $500, X
	CMP TEST_DMCDMAPlusOAMDMA_AnswerKey, X
	BNE FAIL_DMCDMAPlusOAMDMA2
	INX
	CPX #$20
	BNE TEST_DMCDMAPlusOAMDMA_Loop3
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_DMCDMAPlusOAMDMA2:
	JMP FAIL_DMCDMAPlusOAMDMA

TEST_DMCDMAPlusOAMDMA_AnswerKey:      ; C = (cycles stolen by the OAM DMA and the DMC DMA) - 513, see above
	.byte $03, $04, $03, $04, $03, $02, $03, $02, $03, $02, $03, $02, $03, $02, $03, $02
	.byte $03, $02, $03, $02, $03, $02, $03, $01, $02, $03, $04, $03, $04, $03, $04, $03

TEST_DOD_Decode:                      ; index: hits of the 4 runs (bit 0 = probe on time ... bit 3 = 3 cycles early)
	.byte $FF, $00, $FF, $01, $FF, $FF, $FF, $02, $05, $FF, $FF, $FF, $04, $FF, $03, $FF

TEST_DOD_Measure:
	; In: X = position 0-15, <$5B> = 0 (loop 1) or 1 (loop 2). Out: A = c, or $FF for an impossible set of hits. X kept.
	LDA #0
	STA <$5C                          ; the hits
	STA <$59                          ; u: the probe is this many cycles early
TEST_DOD_Measure_Loop:
	JSR TEST_DOD_Run
	LDA <$50
	LSR A                             ; C = hit
	ROR <$5C
	INC <$59
	LDA <$59
	CMP #4
	BNE TEST_DOD_Measure_Loop
	LDA <$5C
	LSR A
	LSR A
	LSR A
	LSR A
	TAY
	LDA TEST_DOD_Decode, Y
	LDX <$5A
	RTS

TEST_DOD_Run:
	; One run. Cycles are counted from the fetch on which R0 lands (4 stolen cycles, then that fetch again = cycle 0).
	; R1 is on cycle 780, R2 on cycle 780 + 784 + (513 + c) of this count.
	STX <$5A
	LDA #LOW(TEST_DOD_Ret)
	LDX #HIGH(TEST_DOD_Ret)
	JSR TEST_OBProbe_Install          ; <$50> = 0, return to TEST_DOD_Ret
	JSR DMASync_50CyclesRemaining
	LDA #$4C                          ; 2
	STA $4010                         ; 6   loop, rate $C: applies from R0's reload
	LDX <$5A                          ; 9
	JSR Clockslide_41                 ; 50: R0 lands on the next opcode fetch (a put, 4 cycles)
	LDA <$5B                          ; 3
	BEQ TEST_DOD_Pre1                 ; loop 1: 6 / loop 2: 5
	JMP TEST_DOD_Common               ; loop 2: 8
TEST_DOD_Pre1:
	JSR ClockslideFromWord            ; loop 1: 518
	.word 512
TEST_DOD_Common:
	JSR Clockslide_100
	JSR Clockslide_50
	JSR Clockslide_32                 ; loop 1: 700 / loop 2: 190
	TXA                               ; +2
	JSR Clockslide64_Minus_A          ; +63 - X (19 + the slide's 44 - A, counted)
	NOP                               ; 8 NOPs: opcode fetches every 2 cycles up to the LDA
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	LDA #2                            ; +2
	STA $4014                         ; the write is its 4th cycle: W = 786 - X (loop 1) / 276 - X (loop 2)
	NOP                               ; the OAM DMA halts this fetch. 4 NOPs: fetches every 2 cycles after it
	NOP
	NOP
	NOP
	TXA                               ; +2
	JSR Clockslide37_Plus_A           ; +37 + X: the code after the write is as much longer as the code before it was shorter
	LDA <$5B                          ; +3
	BNE TEST_DOD_Post2                ; loop 1: +2 / loop 2: +3
	JMP TEST_DOD_PostCommon           ; loop 1: +3
TEST_DOD_Post2:
	JSR ClockslideFromWord            ; loop 2: +512
	.word 512
TEST_DOD_PostCommon:
	JSR Clockslide_100
	JSR Clockslide_27
	LDA <$59                          ; +3
	JSR Clockslide64_Minus_A          ; +63 - u
	LDA #HIGH(TEST_DOD_Ret)           ; +2
	PHA                               ; +3
	LDA #LOW(TEST_DOD_Ret)            ; +2
	PHA                               ; +3
	PHP                               ; +3
	JMP $4000                         ; +3: $4000 is fetched on cycle 1051 - u, i.e. (c - u) cycles after R2
TEST_DOD_Ret:
	RTS

FAIL_ExplicitDMAAbort:
	JMP TEST_Fail


TEST_ExplicitDMAAbort:
	; STATUS: 2A07 form. Test 1 (CheckDMATiming) is the 2A07 cycle clock. Test 2 measures the cycles a DMC DMA steals
	; when the DMC is stopped around it, with a frame-IRQ clock anchored to the DMC (TEST_DAC_Measure), against a key
	; derived from NESdev "DMA" (Bugs, explicit abort) and the 2A07's fetch-only halting. NESdev says it is not known
	; whether the 2A07 has the abort bug; the key assumes the DMC logic is unchanged. Pending hardware.
	LDA <result_DMCDMASync_PreTest
	CMP #1
	BEQ TEST_ExplicitDMAAbort_PALGate
	CMP #2	; the DMA pre-test passed in its 2A07 form
	BNE FAIL_ExplicitDMAAbort	
TEST_ExplicitDMAAbort_PALGate:
	;;; Test 1 [Explicit DMA Abort]: This test relies on precise DMA timing in order to calculate how many cycles the DMA took. Let's test for that now. ;;;
	JSR CheckDMATiming
	CPY #4 ; 
	BNE FAIL_ExplicitDMAAbort
	INC <ErrorCode

	; The explicit abort test is all about what happens to the DMC DMA if the DMC is disabled while the DMA is occurring.
	; 2A07 form. The 2A03 version measured with CalculateDMADuration (an open-bus data read loop a 2A07 DMA never
	; reaches) on a DMA after the DMC was started again. On a 2A07 the DMC cannot be started again before measuring:
	; any further DMA puts the CPU back on the APU's 2-cycle grid and erases the odd cycle being measured. So the clock
	; is the frame IRQ (TEST_DAC_Run):
	;   - $4017 is written a fixed number of cycles before R0 (the sync's DMA), so the frame IRQ comes at a fixed time
	;     after R0. Rate $C: R1 = R0 + 784 is the DMA the $4015 write meets. After that write the DMC is off for good.
	;   - A fixed wait, then CLI and a chain of INX. X when the IRQ is taken counts 2-cycle steps; the run is done twice,
	;     the second time one cycle later, and the two X values added: the sum drops by exactly 1 for each cycle stolen.
	;   - A reference pair with the DMC stopped right after R0 (nothing stolen) gives the zero.
	; KEY, derived. W = the cycle of the $4015 write, R1 = W - 7 + X, always a put cycle. Opcode fetches: every 2 cycles
	; up to W-3 (the STA's), then W+1, W+3, ...
	;   R1 <= W-3: the DMA lands on the first opcode fetch at or after R1: 4 cycles on a put (R1 on a fetch: X = 0, 2, 4),
	;              3 on a get (X = 1, 3).
	;   R1 = W: the write cycle delays the halt to W+1, a fetch on a get cycle; the DMA still happens (as on the 2A03): 3 (X = 7).
	;   R1 = W-2, W-1 (X = 5, 6): the halt has been requested and is still waiting for an opcode fetch when the DMC is
	;              stopped. A 2A03 cannot do this, and no source describes it. Derived from the rule that fits every
	;              documented case: a stop takes effect on the get cycle of the 2nd APU cycle after the write (as a start
	;              does), and a DMA whose read is on that cycle or earlier completes (that is what makes the R1 = W and
	;              R1 = W+1 cases complete). Here the read falls exactly on that cycle: the DMA runs in full, 3 cycles
	;              when it lands on a get (X = 5), 4 on a put (X = 6).
	;   R1 = W+1: stopped 1 cycle before the halt: too late to matter, and W+1 is a fetch: 4 (X = 8).
	;   R1 = W+2: stopped 2 cycles before the halt: the DMA is aborted (NESdev "DMA", Bugs); an aborted DMA whose halt is
	;              delayed does not happen at all, and W+2 is not an opcode fetch: 0 (X = 9).
	;   R1 = W+3: stopped 3 cycles before: aborted, and W+3 is an opcode fetch: the halt takes its one cycle: 1 (X = 10).
	;   R1 >= W+4: stopped in time: 0.
	; If you fail this test, look at $500-$50F and compare with the answer key below.
	LDA #0
	STA <$5E                          ; the explicit-stop run
	STA <$5F                          ; layout A
	STA <$5B                          ; reference: the tested write changes nothing either
	JSR TEST_DAC_Reference
	LDA #0
	STA <$5B                          ; the $4015 value written on the tested cycle: stop
	TAX
TEST_ExplicitDMAAbort_Loop1:
	JSR TEST_DAC_Measure
	STA $500, X
	INX
	CPX #$10
	BNE TEST_ExplicitDMAAbort_Loop1

	;;; Test 2 [Explicit DMA Abort]: Compare results with answer key ;;;
	LDX #0
TEST_ExplicitDMAAbort_Loop2:
	LDA $500, X
	CMP TEST_ExplicitDMAAbort_AnswerKey, X
	BNE FAIL_ExplicitDMAAbort2
	INX
	CPX #$10
	BNE TEST_ExplicitDMAAbort_Loop2

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_ExplicitDMAAbort2:
	JMP TEST_Fail

TEST_ExplicitDMAAbort_AnswerKey:      ; Cycles stolen, see above
	.byte $04, $03, $04, $03, $04, $03, $04, $03, $04, $00, $01, $00, $00, $00, $00, $00

TEST_DAC_Reference:
	; The zero of the clock: a pair of runs in which nothing is stolen after R0. <$57> = the sum of the two X values.
	; Explicit runs (<$5E> = 0): the DMC is stopped right after R0. Implicit runs (<$5E> = 1): the caller has set the
	; tested write's value (<$5B>) to 0, so the sample is never started.
	LDA #0
	STA <$58                          ; explicit runs: stop right after R0
	TAX
	JSR TEST_DAC_Pair
	STA <$57
	LDA #$10
	STA <$58                          ; explicit runs from now on: leave the DMC running after R0
	RTS

TEST_DAC_Measure:
	; In: X = position 0-15. Out: A = cycles stolen = reference sum - this sum. X kept.
	JSR TEST_DAC_Pair
	STA <$56
	LDA <$57
	SEC
	SBC <$56
	LDX <$5A
	RTS

TEST_DAC_Pair:
	; Two runs, the second one cycle later. Out: A = X1 + X2.
	LDA #0
	STA <$59
	JSR TEST_DAC_Run
	LDA <$5C
	PHA
	LDX <$5A
	INC <$59
	JSR TEST_DAC_Run
	PLA
	CLC
	ADC <$5C
	LDX <$5A
	RTS

TEST_DAC_Run:
	; One run. In: X = position, <$5E> = 0 explicit-stop run / 1 implicit-stop run, <$58> = $4015 value written right
	; after R0 in an explicit run ($10: no effect, $00: stop), <$5B> = $4015 value written on the tested cycle, <$5D> =
	; $4010 value for the sample an implicit run starts ($0C, or $4C to loop), <$5F> = 0 layout A / 1 layout B around the
	; write, <$59> = 0 or 1 (one cycle later). Out: <$5C> = X when the frame IRQ was taken.
	; Cycles are counted from the fetch on which R0 lands (4 stolen cycles, then that fetch again = cycle 0); R1 is on
	; cycle 780.
	STX <$5A
	LDA <$5E
	BEQ TEST_DAC_RunExplicit
	; The implicit-stop run. The sync's sample loops; with the loop flag cleared before R0, R0 reads its last byte and the
	; sample ends there. The buffer empties on R1 (cycle 780) and stays empty; E = R2 (cycle 1564) is the next time the
	; output unit would empty it. The tested write (W = 1561 - X = E - 3 - X) starts a 1-byte sample.
	JSR DMASync_50CyclesRemaining
	LDA #$0C                          ; 2
	STA $4010                         ; 6   no loop, rate $C
	LDA #0                            ; 8
	STA $4013                         ; 12  1-byte sample
	LDX <$5A                          ; 15
	LDY <$5B                          ; 18  the value for the tested write
	JSR Clockslide_32                 ; 50: R0 lands on the next opcode fetch (a put, 4 cycles)
	JSR ClockslideFromWord            ; 724
	.word 724
	LDA #0                            ; 726
	STA $4017                         ; 730 4-step mode, IRQ enabled: as far before the tested write as in the explicit run
	LDA <$5D                          ; 733
	STA $4010                         ; 737 rate $C again, with or without the loop flag, for the sample the tested write starts
	JSR ClockslideFromWord            ; 1472
	.word 735
	JMP TEST_DAC_Common               ; 1475
TEST_DAC_RunExplicit:
	JSR DMASync_50CyclesRemaining
	LDA #$4C                          ; 2
	STA $4010                         ; 6   loop, rate $C: applies from R0's reload
	LDA #0                            ; 8
	STA $4017                         ; 12  4-step mode, IRQ enabled: the frame IRQ comes about 33255 cycles from here
	LDX <$5A                          ; 15
	LDY <$5B                          ; 18  the value for the tested write (the slides below leave Y alone)
	JSR Clockslide_32                 ; 50: R0 lands on the next opcode fetch (a put, 4 cycles)
	LDA <$58                          ; 3
	STA $4015                         ; 7   reference runs stop the DMC here; the others write $10, which changes nothing
	JSR ClockslideFromWord            ; 701
	.word 694
TEST_DAC_Common:
	TXA                               ; 703 (explicit) / 1477 (implicit)
	JSR Clockslide64_Minus_A          ; 766 - X (19 + the slide's 44 - A, counted)
	LDA <$5F                          ; 769 - X  the layout of the code around the write
	BEQ TEST_DAC_LayoutA              ; layout A: 772 - X / layout B: 771 - X
	; Layout B: a 3-cycle instruction after the write, so that an event two instructions after it is not on an opcode fetch.
	NOP
	NOP
	NOP
	NOP
	NOP                               ; 781 - X
	LDA <$00                          ; 784 - X
	STY $4015                         ; the write is its 4th cycle: W = 787 - X (explicit) / 1561 - X (implicit)
	NOP                               ; opcode fetches on W+1, W+3 (LDA <$00, 3 cycles), W+6, W+8, W+10, W+12
	LDA <$00
	NOP
	NOP
	NOP
	NOP
	JMP TEST_DAC_Tail                 ; layout B is 4 cycles longer than layout A; its own reference pair has the same 4
TEST_DAC_LayoutA:
	NOP                               ; 6 NOPs: opcode fetches every 2 cycles up to the STY's on W-3
	NOP
	NOP
	NOP
	NOP
	NOP                               ; 784 - X
	STY $4015                         ; the write is its 4th cycle: W = 787 - X (explicit) / 1561 - X (implicit)
	NOP                               ; 6 NOPs: opcode fetches every 2 cycles after the write
	NOP
	NOP
	NOP
	NOP
	NOP
TEST_DAC_Tail:
	TXA                               ; +2
	JSR Clockslide37_Plus_A           ; +37 + X: the code after the write is as much longer as the code before it was shorter
	LDA #$4C                          ; the IRQ vector's RAM stub (the sync used it): JMP TEST_DAC_IRQ
	STA $600
	LDA #LOW(TEST_DAC_IRQ)
	STA $601
	LDA #HIGH(TEST_DAC_IRQ)
	STA $602
	LDA #0
	STA $4015                         ; the DMC is off from here on in every run
	LDA <$59                          ; +3
	BNE TEST_DAC_Later                ; +2, or +3 for the run that is one cycle later
TEST_DAC_Later:
	JSR ClockslideFromWord
	.word 32300                       ; the IRQ falls about 20 INXs into the chain when nothing was stolen
	LDX #0
	CLI
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	INX
	SEI                               ; no IRQ inside the chain: X = 48, which no key matches
	STX <$5C
	JMP TEST_DAC_Done
TEST_DAC_IRQ:
	STX <$5C
	PLA
	PLA
	PLA
TEST_DAC_Done:
	LDA #$40
	STA $4017
	LDA $4015                         ; acknowledge the frame IRQ
	RTS

FAIL_ImplicitDMAAbort:
	JMP TEST_Fail

TEST_ImplicitDMAAbort:
	; STATUS: 2A07 form. Test 1 (CheckDMATiming) is the 2A07 cycle clock. Test 2 measures the cycles stolen when a
	; 1-byte sample is started shortly before the output unit would empty the sample buffer, with the frame-IRQ clock of
	; [Explicit DMA Abort] (TEST_DAC_Measure), against a key derived from NESdev "DMA" (Bugs, implicit stop) and the
	; 2A07's fetch-only halting. NESdev says it is not known whether the 2A07 has these bugs; the key assumes the DMC
	; logic is unchanged, and accepts both documented chip behaviours where they differ. Pending hardware.
	LDA <result_DMCDMASync_PreTest
	CMP #1
	BEQ TEST_ImplicitDMAAbort_PALGate
	CMP #2	; the DMA pre-test passed in its 2A07 form
	BNE FAIL_ImplicitDMAAbort	
TEST_ImplicitDMAAbort_PALGate:
	;;; Test 1 [Implicit DMA Abort]: This test relies on precise DMA timing in order to calculate how many cycles the DMA took. Let's test for that now. ;;;
	JSR CheckDMATiming
	CPY #4 ; 
	BNE FAIL_ImplicitDMAAbort
	INC <ErrorCode

	; The implicit abort test is all about what happens if the reload DMA occurs very briefly after a load DMA on a 1-byte sample with looping disabled.
	; This results in a 1-cycle DMA.
	; 2A07 form (the 2A03 version's three loops measured with CalculateDMADuration; loop 1 is described here, loops 2 and 3 below).
	; The sample buffer is empty and the DMC silent; E is the put cycle on which the output unit would next empty the
	; buffer. A 1-byte, non-looping sample is started by a $4015 write on cycle W = E - 3 - X, followed by 2-cycle NOPs
	; (opcode fetches on W+1, W+3, ...). The value measured is every cycle stolen after the write.
	; KEY, derived:
	;   The load DMA (NESdev "DMA"; Fiskbit, forum t=26827) first tries to halt on the 3rd cycle after a write on a put
	;   cycle: that is an opcode fetch on a get cycle, 3 cycles, the byte is read on W+5. After a write on a get cycle it
	;   tries on the 4th cycle, which is not an opcode fetch here, so it lands on W+5, a put: 4 cycles, read on W+8. (On
	;   a 2A03 that second case halts at once on W+4 and reads on W+6; the difference is the 2A07's fetch-only halting.)
	;   Reading the byte ends the sample. With L = the cycle of that read:
	;     L = E-3: the sample ends in the APU cycle before the reload DMA would be requested: the DMA starts and is
	;              aborted after one cycle (NESdev "DMA", Bugs). E is an opcode fetch here, so the cycle is taken: +1.
	;              X = 5 (write on a put: 3 + 1 = 4) and X = 8 (write on a get: 4 + 1 = 5).
	;     L = E-1: the sample ends in the same APU cycle. Early 2A03s: nothing more. RP2A03H and late RP2A03G: an
	;              unexpected full reload DMA follows at once, 4 more cycles. Which a 2A07 does is not known: both are
	;              accepted. X = 3 (3, or 7) and X = 6 (4, or 8).
	;     anything else: only the load DMA: 3 after a write on a put (odd X), 4 after a write on a get (even X).
	; Loop 2 (error code 3), the 2A07 form of "the 1-cycle DMA is not delayed by a write cycle, it just does not occur":
	; on a 2A07 it does not occur when its cycle is not an opcode fetch. Layout B puts a 3-cycle instruction after the
	; write: opcode fetches on W+1, W+3 (3 cycles), W+6, W+8, ...
	;   write on a put (odd X): the load DMA halts on W+3 (a get), 3 cycles, read on W+5; the CPU resumes on W+6 with the
	;     3-cycle instruction, so E = W+8 (X = 5) is its last cycle, not an opcode fetch: no aborted DMA, 3.
	;   write on a get (even X): the first try on W+4 is inside that instruction; the DMA lands on W+6, a get: 3 cycles
	;     here (4 in loop 1), read on W+8. For X = 8, E = W+11 is an opcode fetch again: the aborted DMA takes its cycle, 4.
	;   In this layout L = E-1 is X = 3 and X = 6: 3, or 7 with the unexpected DMA.
	; Loop 3 (error code 4): the same as loop 1 with the sample looping. Nothing is aborted, because the sample does not
	; end; when the load DMA's read comes before E, the buffer is emptied on E and a reload DMA follows, 4 cycles on the
	; opcode fetch on E (the fetches are on put cycles after the load DMA).
	;   load only (read after E): 4, 3, 4, 3, 4 for X = 0-4.
	;   load + reload: 3 + 4 = 7 (odd X >= 5), 4 + 4 = 8 (even X >= 8).
	;   L = E-1 (X = 3, 6): the reload DMA is held off on the early 2A03 and follows at once on the later ones: 3 or 7, 4 or 8.
	; If you fail this test, look at $500-$50F (loop 1), $520-$52F (loop 2) and $540-$54F (loop 3) and compare with the keys below.
	LDA #1
	STA <$5E                          ; the implicit-stop run
	LDA #0
	STA <$5F                          ; layout A
	STA <$60                          ; set when a value matched the alternate key
	LDA #$0C
	STA <$5D                          ; no loop
	LDY #0
	JSR TEST_IDA_RunLoop              ; loop 1 -> $500
	LDA #1
	STA <$5F                          ; layout B
	LDY #$20
	JSR TEST_IDA_RunLoop              ; loop 2 -> $520
	LDA #0
	STA <$5F                          ; layout A
	LDA #$4C
	STA <$5D                          ; the sample loops
	LDY #$40
	JSR TEST_IDA_RunLoop              ; loop 3 -> $540
	LDA #0
	STA $4015

	;;; Test 2 [Implicit DMA Abort]: Compare results with answer key ;;;
	LDY #0
	LDX #0
	JSR TEST_IDA_Compare
	BNE FAIL_ImplicitDMAAbort2
	INC <ErrorCode

	;;; Test 3 [Implicit DMA Abort]: Compare results with answer key ;;;
	; The 1-cycle DMA does not get delayed, it just doesn't occur at all (2A07: when its cycle is not an opcode fetch).
	LDY #$20
	LDX #$10
	JSR TEST_IDA_Compare
	BNE FAIL_ImplicitDMAAbort2
	INC <ErrorCode

	;;; Test 4 [Implicit DMA Abort]: Compare results with answer key ;;;
	; With the sample looping there is no abort: the reload DMA follows the load DMA.
	LDY #$40
	LDX #$20
	JSR TEST_IDA_Compare
	BNE FAIL_ImplicitDMAAbort2

	;; END OF TEST ;;
	LDA <$60
	BNE TEST_ImplicitDMAAbort_AlternateBehavior
	LDA <RunningAllTests
	BNE TEST_ImplicitDMAAbort_SkipText2
	JSR WaitForVBlank
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $2390
	.byte "Implicit Abort Behavior 2", $FF
	JSR ResetScroll
TEST_ImplicitDMAAbort_SkipText2:
	LDA #9	; success code 2. (no unexpected DMA: as a pre-1990 2A03)
	RTS
;;;;;;;

FAIL_ImplicitDMAAbort2:
	JMP FAIL_ImplicitDMAAbort
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
TEST_ImplicitDMAAbort_AlternateBehavior:
	LDA <RunningAllTests
	BNE TEST_ImplicitDMAAbort_SkipText
	JSR WaitForVBlank
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $2390
	.byte "Implicit Abort Behavior 1", $FF
	JSR ResetScroll
TEST_ImplicitDMAAbort_SkipText:
	LDA #5	; success code 1. (the unexpected DMA: as a post-1990 2A03)
	RTS
;;;;;;;

TEST_IDA_RunLoop:
	; Measures the 16 positions with the current settings into $500+Y. The reference pair comes first.
	STY <$61
	LDA #0
	STA <$5B                          ; reference: the tested write is $00, the sample is never started
	JSR TEST_DAC_Reference
	LDA #$10
	STA <$5B                          ; the tested write starts the sample
	LDX #0
TEST_IDA_RunLoop_Loop:
	JSR TEST_DAC_Measure
	PHA
	TXA
	CLC
	ADC <$61
	TAY
	PLA
	STA $500, Y
	INX
	CPX #$10
	BNE TEST_IDA_RunLoop_Loop
	RTS

TEST_IDA_Compare:
	; Compares the 16 values at $500+Y with the keys at offset X. Out: Z set if every value matched the key or the
	; alternate key; <$60> is set when an alternate value was seen.
	LDA #$10
	STA <$61
TEST_IDA_Compare_Loop:
	LDA $500, Y
	CMP TEST_ImplicitDMAAbort_Keys, X
	BEQ TEST_IDA_Compare_Next
	; The alternate key (the later 2A03's "unexpected DMA") differs only at positions 3 and 6 of each loop: 4 more
	; cycles stolen there.
	LDA TEST_ImplicitDMAAbort_Keys, X
	CLC
	ADC #4
	CMP $500, Y
	BNE TEST_IDA_Compare_Done         ; Z clear: fail
	LDA <$61
	CMP #16-3
	BEQ TEST_IDA_Compare_Alt
	CMP #16-6
	BNE TEST_IDA_Compare_Done         ; Z clear: fail
TEST_IDA_Compare_Alt:
	STA <$60                          ; nonzero: an alternate value was seen
TEST_IDA_Compare_Next:
	INY
	INX
	DEC <$61
	BNE TEST_IDA_Compare_Loop         ; ends with Z set
TEST_IDA_Compare_Done:
	RTS

TEST_ImplicitDMAAbort_Keys:           ; Cycles stolen after the write, see above. Loops 1, 2, 3.
	.byte $04, $03, $04, $03, $04, $04, $04, $03, $05, $03, $04, $03, $04, $03, $04, $03
	.byte $03, $03, $03, $03, $03, $03, $03, $03, $04, $03, $03, $03, $03, $03, $03, $03
	.byte $04, $03, $04, $03, $04, $07, $04, $07, $08, $07, $08, $07, $08, $07, $08, $07
	
TEST_RunSHASHS_AddrInitAXYFS:
	;.word TargetAddress
	;.byte Initial, A, X, Y, Flags, StackPointer
	;.word ResultAddress
	;.byte result, r_A, r_X, r_Y, r_Flags, r_StackPointer
	STA <$FF
	JSR CopyReturnAddressToByte0
	LDY #0
	LDX #0
TEST_RunSHASHS_PreLoop:
	LDA [$0000],Y
	STA <Test_UnOp_OperandTargetAddrLo,X
	INY
	INX
	CPX #16 ; Set up $28 through $2F
	BNE TEST_RunSHASHS_PreLoop
	; With the variables all set up, let's prep the test:
	JSR FixRTS
	LDX <Test_UnOp_ExpectedResultAddrLo
	JSR WriteFFOnEachPageOffsetX
	JSR TEST_UnOpRunTest
	LDX <Test_UnOp_ExpectedResultAddrLo
	JSR RestoreTestResultFromBehavior3
	; Evaluating the test.
	LDA <initialSubTest
	STA <ErrorCode
	JSR Test_UnOpSHASHS_Behavior3
	; If you made it this far, we passed this test!
	; (not necessarily the entire suite, but this specific test, at least)
	LDA UnOpTest_Opcode ; reset this value before the next test, assuming another one follows
	RTS
;;;;;;;

Test_UnOpSHASHS_Behavior3:
	LDX <Test_UnOp_ExpectedResultAddrLo
	JSR ANDByteOnEachPageOffsetX
	CMP <Test_UnOp_ValueAtAddressResult
	BNE FAIL_SHASHS3_Test ; Error code 1: The result at the expected address was incorrect
	INC <ErrorCode
	LDA <Copy_A
	CMP <Test_UnOp_CMP
	BNE FAIL_SHASHS3_Test ; Error code 2: The result of the A register was incorrect
	INC <ErrorCode
	LDX <Copy_X
	CPX <Test_UnOp_CPX
	BNE FAIL_SHASHS3_Test ; Error code 3: The result of the X register was incorrect
	INC <ErrorCode
	LDY <Copy_Y
	CPY <Test_UnOp_CPY
	BNE FAIL_SHASHS3_Test ; Error code 4: The result of the Y register was incorrect
	INC <ErrorCode
	LDA <Copy_Flags
	CMP <Test_UnOp_CM_Flags
	BNE FAIL_SHASHS3_Test ; Error code 5: The result of the flags were incorrect
	INC <ErrorCode
	LDA <Copy_SP2
	CMP <Test_UnOp_CPS
	BNE FAIL_SHASHS3_Test ; Error code 6: The result of the stack pointer was incorrect
	RTS ; Pass!
FAIL_SHASHS3_Test:
	PLA	; Pull of the Return Address
	PLA	;
	PLA
	PLA
	JMP TEST_Fail ; and fail the test.

ANDByteOnEachPageOffsetX:
	; The idea here is that all of these except for one have the value $FF.
	; Therefore, by the time we hit RTS, we read the value we're looking for in A.
	LDA #$FF
	AND <$00, X
	AND $100, X
	AND $200, X
	AND $300, X
	AND $400, X
	AND $500, X
	AND $600, X
	AND $700, X
	RTS
;;;;;;;

WriteFFOnEachPageOffsetX:
	; Initialize stuff for these "behavior 3" tests.
	; Oh hey wait- this overwrites page 4. That's not good.
	; But like- behavior 3 assumes that writing to page 4 is a possibility, so...
	LDA $400, X
	; Where would this never write to?
	STA $7FF ; Pretty sure I never use $FF as the address low byte.
	; This would also pollute page 3, the uninitialized RAM data.
	LDA $300, X
	STA $7FE
	
	LDA #$FF
	STA <$00, X
	STA $100, X
	STA $200, X
	STA $300, X
	STA $400, X
	STA $500, X
	STA $600, X
	STA $700, X
	RTS
;;;;;;;

RestoreTestResultFromBehavior3:
	LDA $7FF
	STA $400, X
	LDA $7FE
	STA $300, X
	RTS
;;;;;;;

TEST_SHS_Behavior3_9B
	PHA ; just used to prevent issues with the PLA in ErrorCodeF
	LDX #0
	JSR ANDByteOnEachPageOffsetX
	CMP #$FF
	BEQ FAIL_SHA_SHS_ErrorCodeF
	JMP TEST_SHS_Behavior3



TEST_SHA_Behavior3_93:
	LDA #$93
	PHA ; push the opcode. This just lets me re-use the upcoming code.
	
	LDA <RunningAllTests
	BNE TEST_SHA_JMPto_Behavior3
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22B0
	.byte " SHA Behavior 3", $FF
	JSR ResetScrollAndWaitForVBlank
TEST_SHA_JMPto_Behavior3:
	JMP TEST_SHA_Behavior3
	
FAIL_SHA_SHS_ErrorCodeF:
	PLA ; pull off the opcode of the test.
	LDA #$3E ; (Error code F) 
	RTS	
	
TEST_SHA_Behavior3_9F:
	LDA #$9F
	PHA ; push the opcode. This just lets me re-use the upcoming code.
	LDA <RunningAllTests
	BNE TEST_SHA_Behavior3
	
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22B0
	.byte " SHA Behavior 3", $FF
	JSR ResetScrollAndWaitForVBlank
	
TEST_SHA_Behavior3:
	; Okay, so your CPU decided to make this as difficult as possible by introducing a magic number into the ABH corruption.
	; When the SHA instruction's indexing crosses a page boundary, the typical result is `ABH = (ABH+1) & A`, or perhaps `ABH = (ABH+1) & A & X`.
	; However, it would appear this console's (or emulator's) result is actually `ABH = (ABH+1) & (A | MAGIC)`. Or maybe there's an X in there too, I have no idea.
	; and since it's impossible on an NROM cartridge to actually know exactly what address / mirror was specifically written to, we cannot know, nor make assumptions.
	; therefore, all we know is the low byte of the target address.
	; We're not actually able to calculate this "MAGIC" value, because we cannot actually know which address / mirror gets written to.
	; in other words, we're going to simply check $0xx, $1xx, $2xx, $3xx, $4xx, $5xx, $6xx, and $7xx after every test.

	; Final checks. If every one of these addresses ($000, $100, $200...) is still $FF, then fail the test.
	LDX #0
	JSR ANDByteOnEachPageOffsetX
	CMP #$FF
	BEQ FAIL_SHA_SHS_ErrorCodeF
	
	; The worst part about all of this is the magic number could cancel out the bitwise AND entirely, nullifying the ABH corruption, but *oh well*.
	; I guess if you didn't even implement the ABH corruption into your emulator you get to pass the SHA and SHS instructions, but I will judge you. Heh.
	PLA
	JSR TEST_UnOp_Setup; Set the opcode
	; This test for "behavior 3" differs from all know documentation, and is honestly annoying to work with, and was a nightmare to research.
	; Special thanks to SNS_Dominic for their Verilog research allowing us to discover there's a magic number affecting ABH.
	; Write: A & (X | Magic) & H
	; Hi = Hi & (X | Magic) ; NOTE: this magic number is not the same magic number used in the value written
	
	; We can not make any assumptions on what "magic" is. Therefore, X needs to always be FF.
	JSR TEST_RunSHASHS_AddrInitAXYFS
	.word $0555
	.byte $FF
	.byte $FF, $FF, $00, (flag_i), $80
	.word $0555
	.byte $06
	.byte $FF, $FF, $00, (flag_i), $80
	
	JSR TEST_RunSHASHS_AddrInitAXYFS
	.word $1D60
	.byte $FF
	.byte $03, $FF, $00, (flag_i), $80
	.word $0560
	.byte $02
	.byte $03, $FF, $00, (flag_i), $80
	
	; Now to make the high byte go unstable.
	JSR TEST_RunSHASHS_AddrInitAXYFS
	.word $1F50 ; $1E90 will be the operand.
	.byte $FF
	.byte $0A, $FF, $80, (flag_i | flag_c | flag_z | flag_v), $80
	.word $0750
	.byte $0A
	.byte $0A, $FF, $80, (flag_i | flag_c | flag_z | flag_v), $80
	; the high byte will only be ANDed with X (FF in this case)
	
	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $8F, $FF, $00, (flag_i), $80
	
	;; END OF TEST ;;
	LDA #13	; Pass, "code 3"
	RTS
;;;;;;;

TEST_SHS_Behavior3:
	PLA
	LDA <RunningAllTests
	BNE TEST_SHS_Behavior3_Skip
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $22D0
	.byte " SHS Behavior 3", $FF
	JSR ResetScrollAndWaitForVBlank
TEST_SHS_Behavior3_Skip:
	
	LDA #$9B
	JSR TEST_UnOp_Setup; Set the opcode
	JSR TEST_RunSHASHS_AddrInitAXYFS
	.word $0555
	.byte $FF
	.byte $FF, $FF, $00, (flag_i), $FF
	.word $0555
	.byte $06
	.byte $FF, $FF, $00, (flag_i), $FF
	
	JSR TEST_RunSHASHS_AddrInitAXYFS
	.word $1D00
	.byte $FF
	.byte $03, $FF, $00, (flag_i), $ff
	.word $0500
	.byte $02
	.byte $03, $FF, $00, (flag_i), $03
	
	JSR TEST_RunSHASHS_AddrInitAXYFS
	.word $1F60 ; $1E90 will be the operand.
	.byte $FF
	.byte $0A, $FF, $80, (flag_i | flag_c | flag_z | flag_v), $5E
	.word $0760
	.byte $0A
	.byte $0A, $FF, $80, (flag_i | flag_c | flag_z | flag_v), $0A

	; Error codes 7-C, 2A07 form. The 2A03 statement: when a DMC DMA halts the CPU on the cycle before the write,
	; the high-byte term drops out of the value written. A 2A07 DMA only halts on an opcode fetch (NESdev forum "PAL DMA
	; behavior", t=25939), so the same request must change nothing: the instruction is run once without a DMA and once
	; with the DMA requested on the cycle before the write, and everything must be identical (TEST_UnOp_DMANoEffect).
	; A CPU that halts there like a 2A03 fails with error 7. This holds for every SHA/SHS behavior. Pending hardware.
	JSR TEST_UnOp_DMANoEffect
	.word $0500
	.byte $5A, $8F, $FF, $00, (flag_i), $9F

;; END OF TEST ;;
	LDA #13	; Pass "code 2"
	RTS
;;;;;;;

FAIL_ALERead:
	JSR WaitForVBlank
	JSR SetUpDefaultPalette
	JMP TEST_Fail


FAIL_HybridAddresses:
	JMP TEST_Fail
TEST_HybridAddresses:

	;;; Test 1 [Hybrid Addresses]: Verify sprite zero hits before running the actual test. ;;;

	JSR VerifySpriteZeroHits ; Use this subroutine to verify if sprite zero hits are working.
	BEQ FAIL_HybridAddresses; And if they aren't, fail the test.
	INC <ErrorCode

	;;; Test 2 [Hybrid Addresses]: Can a well-timed STA $2006 corrupt a nametable fetch? ;;;
	; The answer shouldn't surprise you at this point, because it is yes.
	
	; If you have made it passed the ALE + Read test, then I assume you have implemented proper 2-cycle-long-reads with the PPU.
	; To make a long story short, if the write to $2006 goes through at the right time, the high byte will be determined by new value of the v register,
	; and the low byte will be determined by the octal latch set on the previous cycle.
	
	JSR WriteToPPUADDRWithByte    ; 
	.byte $2F, $19                ; Address $2F19
	.byte $CA, $FF                ; CHR $CA, (a single pixel on row 2) followed by the terminator byte.
	
	JSR ResetScroll_2C00
	
	JSR SetUpSpriteZero      ; A single pixel, (scanline 4, dot 200)
	.byte $05, $C0, $00, $C8 ;
	
	JSR Sync_ToLine0Dot1     ; Sync to dot 1 of scanline 0.
	JSR ClockslideFromWord   ; stall 578 CPU cycles: the writes below land on the 2C02 version's dots (3.2 dots per CPU cycle).
	.word 578
	LDA #$2F
	STA $2006
	LDA #0
	STA $2006
	
	; Okay, what happens here?
	; In this case, the moment the write to $2006 updates the v register, the PPU Address bus was $2C19
	; This was on the second cycle of an 8-cycle read of the background, so under normal conditions, we would read from address $2C19.
	; Keep in mind, that the address bus is updated *every ppu cycle*. The upper 6 bits are updated as well before the read occurs.
	; Since the upper 6 bits for the nametable fetch are based on the v register, updating v will change the upper 6 bits. 
	; In this case, the high byte is using the new value of v (which is $2F), but the low byte is using the octal latch. (which is $19)
	; Since the values written to v would result in address $2F00, and the octal latch is $19, the "hybrid address" is $2F19, and that's where we read from for this nametable fetch.
	; And of course, that leads to a sprite zero hit.

	JSR WaitForVBLSpriteZeroHit   ; Wait for vblank and load A with $2002.6
	BNE TEST_HybridAddresses_Pass ; Pass the test if the sprite zero hit occurred. Otherwise, check for alignment 2's timing.
	
	; If the console is in alignment 2, then I need to run the test one scanline later.
	; This is the exact same test, but on scanline 5 instead.
	
	INC $200 ; Move sprite zero down one scanline.
	
	JSR Sync_ToLine0Dot1     ; Sync to dot 1 of scanline 0.
	JSR ClockslideFromWord   ; stall 692 CPU cycles: the writes below land on the 2C02 version's dots (3.2 dots per CPU cycle).
	.word 692
	LDA #$2F
	STA $2006
	LDA #0
	STA $2006

	JSR WaitForVBLSpriteZeroHit   ; Wait for vblank and load A with $2002.6
	BEQ FAIL_HybridAddresses ; Pass the test if the sprite zero hit occurred.

TEST_HybridAddresses_Pass

	;; END OF TEST ;;	

	LDA #1
	RTS
;;;;;;;


FrozenOAM2Inc_OAM:
	.byte $C1, $24, $00; $FF
	; becomes $C1, $C1, $C1, $C1
	
FrozenOAM2Inc_OAM2:
	.byte $C2, $24, $00; $FF
	; becomes $C2, $C2, $C2, $C2

TEST_FrozenOAM2Inc:

	;;; Test 1 [Frozen OAM2 Increment]: Verify sprite zero hits before running the actual test. ;;;

	JSR VerifySpriteZeroHits ; Use this subroutine to verify if sprite zero hits are working.
	BEQ FAIL_FrozenOAM2Inc; And if they aren't, fail the test.
	INC <ErrorCode

	;;; Test 2 [Frozen OAM2 Increment Flag]: Does the "OAM2 Overflowed" flag prevent the OAM2 Address from incrementing during Sprite Fetch?. ;;;
	; When OAM2 is full, the PPU prevents further increments of the OAM2 Address, so the OAM2 Address is frozen at index 0.
	; This flag that prevents the OAM2 Address from incrementing (The "OAM2 Overflowed" flag) is cleared if rendering is enabled during dots 63, 255, and 339.
	; So if OAM2 is full and rendering is disabled, then re-enabled on (or after) dot 256, the sprite fetch stage will continuously read from index 0 of OAM2 for every object.

	; In this example, OAM2 will be:
	; C1 24 00 FF C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0 C0
	; But due to the "OAM2 Overflowed" flag, the data will be processed as if it was:
	; C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1 C1
	
	; Set up primary OAM:
	LDX #0
TEST_FrozenOAM2Inc_OAMLoop:
	LDA FrozenOAM2Inc_OAM, X
	STA $200, X
	INX
	CPX #$03
	BNE TEST_FrozenOAM2Inc_OAMLoop
	LDA #$FF
TEST_FrozenOAM2Inc_OAMLoop2:
	STA $200, X
	INX
	CPX #$E4
	BNE TEST_FrozenOAM2Inc_OAMLoop2
	LDA #$BF
TEST_FrozenOAM2Inc_OAMLoop3:
	STA $200, X
	INX
	BNE TEST_FrozenOAM2Inc_OAMLoop3	
	; Set up the nametable for the sprite zero hit:
	
	JSR DisableRendering
	JSR ClearNametable2_With24
	JSR SetPPUADDRFromWord
	.byte $2F, $18
	LDA #$CB
	STA $2007
	JSR ResetScroll_2C00

	; Sync to a specific dot
	JSR Sync_ToLine0Dot1 ; This also performs the OAM DMA with page 2.
	; Wait for Scanline $C2, where we evaluate OAM, and disable rendering after OAM1 is completely evaluated.
	JSR ClockslideFromWord
	.word 53990
	; PAL timing. This subtest needs two exact dots: rendering must go off after the evaluation of scanline 194 has
	; wrapped the secondary OAM address (the "frozen" increment), which takes effect from dot 242 on, and must come
	; back on at exactly dot 257 of scanline 196 (on, but not yet on at dot 256, so the vertical scroll is not
	; incremented). At 3.2 dots per CPU cycle the writes of one CPU/PPU phase cannot hit both, so this wait is one
	; PAL frame longer: 33248 cycles is half a cycle (1.6 dots) more than a 33247.5-cycle frame, which moves the
	; phase. Measured: the writes land on dot 242.4 (effective 245) and dot 254.8 (effective 257), as the 2C02
	; version's do (effective 243 and 257). The CPU/PPU phase of a real console is not validated (pending hardware).
	LDA #0
	STA $2001 ; Disable rendering on dot 242 of scanline 194.
	; NOTE: This avoids OAM corruption since the OAM Address was 0.
	JSR Clockslide_200
	BIT <$00
	NOP
	NOP
	NOP
	NOP ; 217 CPU cycles (694.4 dots) to the write below
	LDA #$1E
	STA $2001	
	; NOTE: Rendering is enabled on dot 256, but the PPU's vertical scroll is NOT incremented.
	; And just like that, the "Freeze OAM2 Increment Flag" is still raised, so only OAM2[0] is read for the entirety of sprite fetch.
	
	JSR Clockslide_100
	LDA $2002
	AND #$40
	BEQ FAIL_FrozenOAM2Inc
	
	INC <ErrorCode
	BNE TEST_FrozenOAM2Inc_Cont
	
FAIL_FrozenOAM2Inc:
	JMP TEST_Fail
	
TEST_FrozenOAM2Inc_Cont:
	;;; Test 3 [Frozen OAM2 Increment Flag]: The Freeze OAM2 Increment Flag is raised any time the OAM2 address overflows. ;;;
	; We're going to test this by making the OAM2 address overflow during sprite fetch, (which happens every scanline under normal execution on dot 321) and then disable rendering until next sprite fetch.
	; The result is OAM2 reading the value $C2 for every step of Sprite Fetch.
	JSR ClearPage2
	LDX #0
TEST_FrozenOAM2Inc2_Loop:
	LDA FrozenOAM2Inc_OAM2, X
	STA $200, X
	INX
	CPX #$03
	BNE TEST_FrozenOAM2Inc2_Loop
	
	JSR WaitForVBlank ; avoid palette corruption.
	JSR DisableRendering
	JSR ClearNametable2_With24
	JSR SetPPUADDRFromWord
	.byte $2F, $18
	LDA #$CC
	STA $2007
	JSR ResetScroll_2C00
	
	; Sync to a specific dot
	JSR Sync_ToLine0Dot1 ; This also performs the OAM DMA with page 2.
	; Wait for Scanline $C2, where we evaluate OAM, and disable rendering after OAM1 is completely evaluated.
	JSR ClockslideFromWord
	.word 20981
	
	LDA #0
	STA $2001 ; Disable rendering on dot 325 of scanline 196
	
	JSR ClockslideFromWord
	.word 292 ; 298 CPU cycles (953.6 dots) after the write above: rendering back on at dot 257 of scanline 199
	
	LDA #$1E
	STA $2001 ; Enable rendering on dot 256 scanline 199
	
	JSR Clockslide_100
	LDA $2002
	AND #$40
	BEQ FAIL_FrozenOAM2Inc2
	INC <ErrorCode

	;;; Test 4 [Frozen OAM2 Increment Flag]: This one is pretty much just a false-positive prevention. ;;;
	; Just making sure you aren't freezing the OAM2 Increment at a time where you shouldn't be.

	JSR Sync_ToLine0Dot1 ; This also performs the OAM DMA with page 2.
	JSR ClockslideFromWord
	.word 20987
	
	LDA #0
	STA $2001 ; Disable rendering on dot 340 of scanline 196. (OAM2 address will still be reset to $00, also clearing the OAM2 Overflow flag)
	
	JSR ClockslideFromWord
	.word 287 ; 293 CPU cycles (938 dots at 3.2 per cycle) after the write above
	
	LDA #$1E
	STA $2001 ; Enable rendering on dot 256 scanline 199
	; The OAM2 Overflowed flag is NOT set, so this test does NOT trigger a sprite zero hit.
	
	JSR Clockslide_100
	LDA $2002
	AND #$40
	BNE FAIL_FrozenOAM2Inc2

	;; END OF TEST ;;	

	LDA #1
	RTS
;;;;;;;
	
FAIL_FrozenOAM2Inc2:
	JMP TEST_Fail
	
FAIL_MisalignedOAM2Addr:
	JMP TEST_Fail
	
;;;;

TEST_APURegActivation_Finale:
	LDA #0
	STA $4015
	; The controller ports might not have been visible by the OAM DMA, but did the controller ports get clocked?
	; This is not an error code: different consoles behave differently, so the result is only printed.
	LDA #0
	STA <dontSetPointer ; prep this, since we're drawing stuff.
	LDA $4016
	LDA $4016	; it is assumed the B button is not pressed during the test.
	LSR A
	BCS APURegActConflictJmp
	; And the controller ports were NOT clocked here!
	LDA <RunningAllTests
	BNE TEST_APURegActivation_Res1
	JSR PrintTextCentered
	.word $2350
	.byte "OAM DMA Bus Conflict no Clock", $FF
	JSR ResetScroll
TEST_APURegActivation_Res1:
	LDA #5 ; Success Code 1
	RTS

APURegActConflictJmp:
	JMP TEST_APURegActivation_ConflictClocked
	
	; [Arbitrary Sprite zero] is placed here, in free space before $DFF8.
TEST_ArbitrarySpriteZero:
	;;; Test 1 [Arbitrary Sprite Zero]: Sprite 0 should trigger a sprite zero hit. No other sprite should. ;;;
	JSR PREP_SpriteZeroHit
	JSR EnableRendering_S ; start rendering sprites!
	JSR OAMDMAWithPage2 ; OAM DMA
	JSR ClockslideFromWord ; Wait long enough for VBlank to be over and the sprite zero hit to occur: PAL VBlank is 7459
	.word 7646             ; CPU cycles (the 2C02 version waits 3000 of a 2273-cycle VBlank).
	LDA $2002	; Bit 6 should be set, since the sprite zero hit should have occurred.
	AND #$40
	BNE P3SpriteZero_1
FAIL_ArbitrarySpriteZero1_N9:
	JMP FAIL_ArbitrarySpriteZero1
P3SpriteZero_1:
	LDX #1
TEST_ArbitrarySpriteZeroLoop:
	JSR ClearPage2
	JSR WaitForVBlank
	JSR InitializeSpriteX
	;    YPos, CHR, Att, XPos
	.byte $00, $FC, $00, $08
	JSR OAMDMAWithPage2 ; OAM DMA
	JSR ClockslideFromWord ; Wait long enough for VBlank to be over and the sprite zero hit to occur: PAL VBlank is 7459
	.word 7646             ; CPU cycles (the 2C02 version waits 3000 of a 2273-cycle VBlank).
	LDA $2002	; Bit 6 should be set, since the sprite zero hit should have occurred.
	AND #$40
	BNE FAIL_ArbitrarySpriteZero1_N9
	INX
	CPX #64
	BNE TEST_ArbitrarySpriteZeroLoop
	INC <ErrorCode	
	
	;;; Test 2 [Arbitrary Sprite Zero]: The first processed sprite of a scanline is treated as "sprite zero". ;;;
	; This test is a bit tricky to understand. Let's break down the sprite evaluation process by which ppu cycles in a scanline are doing which task.
	; PPU cycle >= 1 && PPU cycle <= 64: clear Secondary-OAM.
	; PPU cycle >= 65 && PPU cycle <= 256: Sprite evaluation
	; PPU cycle >= 257 && PPU cycle <= 320: Shift register initialization. (Every one of these cycles also clears PPUOAMAddress to 0.)
	;
	; Keep in mind, on scanline n, we're processing the OAM data in preparation for scanline n+1.
	; (So the sprites drawn on, for example, scanline 6 were evaluated during the rendering of scanline 5.)
	;
	; Let's take a deep look into how Sprite Evaluation works on any given scanline. (PPU cycle >= 65 && PPU cycle <= 256)
	; for odd ppu cycles: read index "PPUOAMAddress" of OAM. Let's call the value read "S"
	;	- "PPUOAMAddress" is the value set by writing to $2003.
	;	- for our example here, assume PPUOAMAddress is zero, reset during the shift register initialization from the previous scanline.
	; for even cycles: Evaluate "S" and determine if this sprite should be drawn on the next scanline.
	;	- Depending on how the evaluation goes, modify PPUOAMAddress. Typically increment by 1 or 4. (actually "it's complicated", but that's for a different test.)
	; Let's focus on the even cycles.
	; First of all, if Secondary-OAM is full, the behavior is different. Let's focus on when Secondary-OAM is not full.
	; STEP 1: Check that the Y position of this object is in range of this scanline.
	;	- The value checked here is "S", which was read in the previous PPU cycle. In this example, "S" should be index 0 of OAM, since PPUOAMAddress was cleared in the previous scanline.
	;	- If the current scanline number-"S" is positive, and less than 8 (or 16 if the sprites are using the 8 by 16 mode) then this object is in range for this scanline.
	;	- That previous sentence was just a verbose way of calculating "yes, this object should be rendered on the next scanline".
	;	- Now, if Secondary-OAM is not full (in this example it is still empty, so yeah- it's not full) we know this object will be in the next scanline, so add it to Secondary-OAM.
	;	- In addition to being added to Secondary-OAM, if this is PPU cycle 66 of a scanline, it is assumed that we are processing sprite zero, so raise a flag indicating sprite zero exists on the next scanline.
	; STEP 2 to 4: Read "S" as the CHR data, attributes, and X position respectively. (each of these steps happen 2 ppu cycles after the previous step, since we need to read "S" from OAM again)
	;	- There's actually some wild stuff going on with the X position, but that's for a different test.
	;
	; So to recap, read the Y position, and on the following cycle, see if it's in range. If it is, and this is PPU cycle 66 of a given scanline, raise a flag indicating sprite zero exists on the next scanline.
	; - this "flag" essentially says, Secondary-OAM index 0 is "Sprite Zero", as in, a Sprite Zero hit will occur if a "solid pixel" of "sprite zero" overlaps a "solid pixel" of the background.
	; - which is, again, a really verbose way of saying "run a check for a sprite zero hit next scanline" if the value of "S" on ppu cycle 66 was in range for this scanline. 
	;
	; Duh. If you've implemented sprite zero hits, you should be following along. 
	; Perhaps that "flag" isn't the exact way your emulator checks if a sprite is "sprite zero", but it will make sense in a moment why I'm phrasing it this way.
	;
	; What happens if you write to $2003 after the "Shift register initialization" and before "Sprite evaluation"?
	; Well, PPUOAMAddress won't be $00 when sprite evaluation begins.
	; So the first sprite processed on cycle 66 won't necessarily be index zero of OAM.
	; But if "S" is in range of the scanline, and it's cycle 66, then the next scanline will consider Secondary-OAM index 0 as "sprite zero", even if it isn't OAM index 0.
	;
	; In other words, it *is* possible for an object that isn't OAM index 0 to trigger a sprite 0 hit!

	; On a completely unrelated topic, writing to $2003 is all sorts of jank, and I need my test here to prevent that "jankiness" from ruining the results.
	; This behavior appears to only happen on CPU/PPU clock alignment 3:
	; writing to $2003 can copy 8 bytes of OAM from $20 to $27, and paste these values at:
	; The old PPUOAMAddress & $F8
	; The new PPUOAMAddress & $F8
	; So we also want to the 8 values starting at $20 to match the 8 values we want at the new PPUOAMAddress

	; Since this test is a doozy, I will comment every line and explain why I'm doing this.
	JSR ClearPage2				; Let's clear page 2. I'm using page 2 for the OAM DMA, so OAM will be a copy of $200 - $2FF
	JSR WaitForVBlank			; Wait for VBlank. I'm going to disable rendering next, and I'd prefer if I waited for VBlank to do that.
	JSR DisableRendering		; Rendering is now disabled. Rendering needs to be disabled for the upcoming VblSync_Plus_A subroutine to work properly.
	LDX #32						; Let's initialize Sprite 32 at screen coordinates ($08, $00)
	JSR InitializeSpriteX		; This subroutine reads the following 4 bytes, and adjusts the return address accordingly, so the following 4 bytes are not executed.
	.byte $00, $FC, $00, $08	; Y Position, Pattern Table Index, Attributes, X position  
	LDX #8						; Let's also initialize Sprite 8 with the same values, so the $2003 corruption doesn't break anything.
	JSR InitializeSpriteX		; This subroutine reads the following 4 bytes, and adjusts the return address accordingly, so the following 4 bytes are not executed.
	.byte $00, $FC, $00, $08	; Y Position, Pattern Table Index, Attributes, X position  
	LDA #0						; A=0, since this next subroutine syncs to PPU cycle A of VBlank, and I want to sync to cycle 0.
	JSR VblSync_Plus_A  		; Sync the next CPU cycle to PPU cycle 0 of VBlank. (cycle 1 of scanline 241)
								; The CPU is now at PPU cycle 0 of VBlank.
								; PAL: the $2003 write below has to land at the end of the pre-render line (scanline 311),
								; just before scanline 0's sprite evaluation; 71 scanlines of 341 dots after VBlank begins,
								; 3.2 dots per CPU cycle. The wait was set by measurement: the write lands on dot 339 of
								; scanline 311, as the 2C02 version's lands on dot 339 of scanline 261.
	LDA #0
	STA $2003					; OAMADDR = 0: the 2C07's forced refresh moved it while rendering was off.
	LDA #02						; (+2 CPU cycles)   A = 2, so the OAM DMA will use page 2
	STA $4014					; (+518 CPU cycles) Run the OAM DMA with page 2.
	LDA #32*4					; (+2 CPU cycles) Load A with 32*4 (128, or $80) which is the OAM address for the object we initialized.
	JSR EnableRendering			; (+30 CPU cycles) Enable rendering of both the background and sprites, so the sprite zero hit can occur.
	JSR ClockslideFromWord
	.word 6979			; the $2003 write below lands on dot 339 of scanline 311 (see above).
	STA $2003					; Store A ($80) at PPUOAMAddress. (and probably copy 8 instances of $FF from OAM[$00] to OAM[$20], which won't break anything)
								; Now, the sprite evaluation will occur with sprite 8 getting processed first.
								; Since this object is the first one processed, PPU cycle 66 will check if it is in range of the current scanline.
								; and if it is (it is), it will be treated as sprite zero for the purposes of triggering a sprite zero hit, despite being sprite 8.
	JSR Clockslide_500			; Wait a few scanline for this entire sprite to be drawn
	LDA $2002					; Read PPUSTATUS
	AND #$40					; mask away every bit except the Sprite Zero Hit flag.
	BNE P3SpriteZero_3
FAIL_ArbitrarySpriteZero_N11:
	JMP FAIL_ArbitrarySpriteZero
P3SpriteZero_3:
	JSR Clockslide_PALFrame		; Let's wait an entire PAL frame and check again to weed out potential false positives.
	LDA $2002					; Read PPUSTATUS
	AND #$40					; mask away every bit except the Sprite Zero Hit flag.
	BNE FAIL_ArbitrarySpriteZero_N11
	
	INC <ErrorCode			; And if we passed this, increment the error code for the next test.
	
	;;; Test 3 [Arbitrary Sprite Zero]: Misaligned OAM can properly draw a sprite, and yes, it can even trigger a sprite zero hit. ;;;
	; So in that previous test, PPUOAMAddress manually set to a non-zero value just before sprite evaluation. However, this value was a multiple of 4, so it wasn't too complicated.
	; Now things are getting complicated, because we need to talk about what happens in sprite evaluation if PPUOAMAddress is NOT a multiple of 4.
	;	- I am referring to this as "misaligned OAM"
	;	- To be clear, there is also some very specific behavior with misaligned OAM (if the y position is NOT in range) that cannot be checked with sprite zero hits.
	;	- That will be tested in a different test.
	; Let's begin with a misaligned object that passes the "Y Position in range of scanline check"
	; Let's write all of this at $0221.
	; Keep in mind, the OAM attribute byte doesn't have bits 2, 3, or 4, and since we're misaligned, now our CHR Pattern is missing those bits.
	; The CHR Pattern of our choice is essentially bitwise ANDed with $E3.
	; That's why tile $E3 in the pattern data is just a full square.
MisalignedOAM_SpriteZeroTest:   ; I re-use this code in the Misaligned OAM test.
Address2004_SpriteZeroTest:     ; I also re-use this code in the $2004 behavior test.
	JSR ClearPage2				; Same as above. Clear page 2.
	JSR WaitForVBlank			; Same as above. Wait for VBlank.
	JSR DisableRendering		; Same as above. Disable rendering for the VBL Sync subroutine.
	LDX #$81					; We're going to write this at OAM $81
	JSR InitializeOAMAddrX		; Similar to the other subroutine, but this one doesn't multiply X by 4.
	.byte $00, $E3, $00, $08	; Same as above. These bytes don't get executed. Use pattern $E3.
	LDX #$21					; We're going to write this at OAM $21, so the $2003 corruption doesn't break anything.
	JSR InitializeOAMAddrX		; Similar to the other subroutine, but this one doesn't multiply X by 4.
	.byte $00, $E3, $00, $08	; Same as above. These bytes don't get executed. Use pattern $E3.
	LDA #0						; Same as above. Sync to ppu cycle 0 of VBlank. 
	JSR VblSync_Plus_A  		; Same as above. Sync to ppu cycle 0 of VBlank. 
	LDA #0
	STA $2003					; OAMADDR = 0 (see test 2)
	LDA #02						; Same as above. A=2 for the OAM DMA.
	STA $4014					; Same as above. Run the OAM DMA with page 2.
	LDA #$81					; Load A with $81, which we will write to $2003 to offset the OAM address.
	JSR EnableRendering			; Same as above. Enable rendering sprites + background.
	JSR ClockslideFromWord
	.word 6977			; 2 CPU cycles earlier than in test 2: dot 335.8 of scanline 311 (2C02 version: 336 of 261).
	STA $2003					; Store A ($81) at a mirror of PPUOAMAddress. (and probably copy 8 instances of $FF from OAM[$00] to OAM[$20], which won't break anything)
	JSR Clockslide_500			; Same as above. Wait a few scanline for this entire sprite to be drawn
	LDA $2002					; Read PPUSTATUS
	AND #$40					; Same as above. mask away every bit except the Sprite Zero Hit flag.
	BEQ FAIL_ArbitrarySpriteZero_N11
	
	;; END OF TEST ;;
	JSR ClearOverscanNametable
	LDA #1
	RTS
;;;;;;;
KEYDATA_3:
	.byte $01, $35
	.byte $83, $08
	.byte $0D, $3F, $80, $40, $80, $45, $80, $42, $80, $4F, $80, $50, $80, $55
	.byte $83, $08
	.byte $0D, $5F, $80, $60, $80, $65, $80, $62, $80, $6F, $80, $70, $80, $75
	.byte $83, $08
	.byte $07, $7F, $80, $80, $80, $81, $80, $82
	.byte $83, $06
	.byte $1B, $84, $80, $88, $80, $8C, $80, $90, $80, $94, $80, $98, $80, $9C, $80, $A0
	.byte $80, $A4, $80, $A8, $80, $AC, $80, $B0, $80, $B4, $80, $B8
	.byte $80, LOW(KEYDATA_4), HIGH(KEYDATA_4) ; continued
	.org $DFF8
TEST_APURegActivation_ConflictClocked:
	LDA #9 ; Success Code 2
	RTS

	.bank 3
	.org $E000

TEST_ControllerClocking_Strobe:
	LDA #1
	STA $4016 ; write 1 to $4016 to strobe the controllers.
	LSR A
	STA $4016 ; Write 0 to $4016 to finish strobing the controller.
	RTS
;;;;;;;

TEST_ControllerClocking_JMP_Famicom:
	JMP TEST_ControllerClocking_FamicomBehavior

FAIL_ControllerClocking:
	JMP TEST_Fail

TEST_ControllerClocking:
	; STATUS: DOC-BACKED [DMC] Tests 6-7: NESdev "Controller reading": a DMC DMA landing on a $4016 read gives the shift register
	; an extra clock on CPUs that have the glitch, and "This glitch is fixed in the 2A07 CPU used in the PAL NES" (also NESdev "APU DMC":
	; "This problem has been fixed on the 2A07"). So on the 2A07 the LDA $4016 hit by the DMA clocks the controller
	; once, as without a DMA: tests 6 and 7 both count 7. The put/get comments below describe a CPU WITH the double
	; clock, not the 2A07.
	LDA #0
	STA $4015	; This shouldn't be running right now anyway, but better safe than sorry.
	;;; Test 1 [Controller Clocking]: Reading $4016 more than 8 times will always result in bit 0 being set to 1 ;;;
	; Please don't hold DPad Right during this test.
	JSR TEST_ControllerClocking_Strobe
	JSR ReadControllerInto50_and_A
	; Controller 1 was just read 8 times.
	LDA $4016 ; Reading it a ninth time (and any further times) should always have a 1 in bit 0.
	AND #1
	BEQ FAIL_ControllerClocking
	LDA $4016 ; Read it a tenth time just to be sure.
	AND #1
	BEQ FAIL_ControllerClocking
	INC <ErrorCode
	
	;;; Test 2 [Controller Clocking]: Reading $4016 while the controllers are being strobed does not update the shift register inside the controller. ;;;
	; The shift register is constantly being reloaded while it is strobed, so until clearing the strobe, the shift register always returns the A button.
	; This test will fail if ANY button other than A is being pressed. Do not press any other buttons during this test, thanks. :)

	STA $4016 ; A=1, strobe the controller.
	LDX #8
TEST_ControllerClocking_Strobedloop:
	LDA $4016
	DEX
	BNE TEST_ControllerClocking_Strobedloop
	STX $4016 ; unstrobe the controller.
	LDA $4016 ; read A.
	LDX #1
TEST_ControllerClocking_2Strobedloop:
	LDA $4016
	INX
	AND #$01
	BEQ TEST_ControllerClocking_2Strobedloop
	CPX #9
	BNE FAIL_ControllerClocking
	INC <ErrorCode

	;;; Test 3 [Controller Clocking]: SLO Absolute, X works in this emulator ;;;
	; This upcoming test requires SLO to be implemented, so let's confirm it works.
	JSR TEST_SLO_1F
	LDX #3
	STX <ErrorCode
	CMP #1
	BNE FAIL_ControllerClocking
	INC <ErrorCode

	;;; Test 4 [Controller Clocking]: What happens on two consecutive read cycles from $4016? ;;;
	; There are actually 2 outcomes here.
	; Famicom: The controller gets clocked twice.
	; NES / AV Famicom: The controller is not clocked on consecutive reads from $4016.
	JSR TEST_ControllerClocking_Strobe
	LDX #0
	LDA $4016 	; We need the make sure the dummy write to $4016 doesn't have bit 1 set. So uh... don't press B during this test either. Thanks.
	.byte $1F	; SLO Absolute, X
	.word $4016 ; Double-Read address $4016
	; Let's see how many times this instruction clocked the controllers
TEST_ControllerClocking_Loop1:
	LDA $4016
	AND #1
	BNE TEST_ControllerClocking_ExitLoop1
	INX
	BNE TEST_ControllerClocking_Loop1
TEST_ControllerClocking_ExitLoop1:
	; How many times did this loop before reading a 1 in bit 0?
	CPX #5
	BMI FAIL_ControllerClocking ; This should loop a minimum of 6 times.
	BEQ TEST_ControllerClocking_JMP_Famicom ; If it looped 6 times, it had famicom behavior.
	; Otherwise, NES / AV Famicom behavior.
	INC <ErrorCode
	
	;;; Test 5 [Controller Clocking]: The double-read will always read the same value as the first read. (on a NES / AV Famicom) ;;;
	JSR TEST_ControllerClocking_Strobe
	LDX #7
TEST_ControllerClocking_Loop2:
	LDA $4016 ; Read from $4016 7 times.
	DEX
	BNE TEST_ControllerClocking_Loop2
	; X is now zero.
	.byte $1F	; SLO Absolute, X
	.word $4016 ; Double-Read address $4016
	AND #2		; If the double read picked up the ninth value of the shift register, then you fail the test.
	BNE FAIL_ControllerClocking
	INC <ErrorCode

	;;; Test 6 [Controller Clocking]: The DMC DMA can clock the controller. ;;;
	; This is pretty much the exact same thing as the [DMA + $4016] test
	JSR DMASync_50CyclesRemaining
	JSR TEST_ControllerClocking_Strobe ; +6 +2 +4 +2 +4 +6 = 24 CPU cycles.
	JSR Clockslide_23
	; 3 cycles until the DMA
	LDA $4016
	; put : halt cycle. Read $4016.
	; get : halt cycle. Read $4016. (Consecutive read, so this does not clock the controller.)
	; put : dummy read. Read $4016. (Consecutive read, so this does not clock the controller.)
	; get :             Read sample address. (Also bus conflict with $4000, but that won't affect anything since reading that address is all open bus.)
	; LDA $4016 :       Read $4016. (Non-consecutive, so this clocks again.)
	
	; X is zero.
TEST_ControllerClocking_Loop3:
	LDA $4016
	AND #1
	BNE TEST_ControllerClocking_Exit3
	INX
	BNE TEST_ControllerClocking_Loop3
TEST_ControllerClocking_Exit3:
	CPX #7	; [DMC] DOC-BACKED: the 2A07 has no DMC double clock of $4016 (NESdev "Controller reading").
	BNE FAIL_ControllerClocking2
	INC <ErrorCode

	;;; Test 7 [Controller Clocking]: The DMC DMA bus conflicting with $4016 counts as a consecutive read, so LDA $4016 would only end up clocking once in that situation. ;;;
	JSR TEST_ControllerClocking_Strobe
	JSR DMASync_50CyclesRemaining
	LDA #4		;+2
	STA $4013	;+4 sample length = #4 * 16 + 1 = 65 (or $41 in hex)
	LDA #$BF	;+2
	STA $4012	;+4 Sample address is $EFC0 (TEST_DMC_ConflictsSample)
	LDA #$4F	;+2
	STA $4010	;+4 fastest rate. (also loop, so it refreshes the address and length)
	LDX #$0	;+2
	JSR ClockslideFromWord
	.word 424 ; [DMC] DOC-BACKED: PAL rate $F is 400 CPU cycles (50 * 8).
	; Next DMA in 4 cycles
TEST_ControllerClocking_Loop4: ; [DMC] DOC-BACKED: PAL rate $F DMA every 400 CPU cycles.
	JSR ClockslideFromWord
	.word 389
	INX	; +2   Increment X for the next loop.
	CPX #$16 ; +2   If X = $40, we exit the loop.
	BNE TEST_ControllerClocking_Loop4 ; +3 if looping. +2 if not. (total outside the clockslide = 29. 432-29 = 403)
	; Next DMA in 3 cycles.
	LDA $4016
	; put : halt cycle. Read $4016.
	; get : halt cycle. Read $4016. (Consecutive read, so this does not clock the controller.)
	; put : dummy read. Read $4016. (Consecutive read, so this does not clock the controller.)
	; get :             Read sample address. (Also bus conflict with $4016, which is yet another consecutive read.)
	; LDA $4016 :       Read $4016. (Consecutive read, since the bus conflict also read from $4016, so this does not clock the controller.)
	LDX #0
TEST_ControllerClocking_Loop5:
	LDA $4016
	AND #1
	BNE TEST_ControllerClocking_Exit5
	INX
	BNE TEST_ControllerClocking_Loop5
TEST_ControllerClocking_Exit5:
	CPX #7 ; DOC-BACKED: no extra $4016 clock from the DMC DMA on the 2A07 (NESdev "Controller reading"), so one clock.
	BNE FAIL_ControllerClocking2	
	BEQ TEST_ControllerClocking_Continue
	
FAIL_ControllerClocking2:
	JMP TEST_Fail

TEST_ControllerClocking_Continue:
	
	;; END OF TEST ;;
	LDA <RunningAllTests
	BNE TEST_ControllerClocking_SkipText
	JSR WaitForVBlank
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $2370
	.byte "  $4016 Double-Read like NES  ", $FF
	JSR ResetScroll
TEST_ControllerClocking_SkipText:
	LDA #5 ; success code 1 (NES / AV Famicom)
	RTS
;;;;;;;

TEST_ControllerClocking_FamicomBehavior:
	; If this console or emulator is showing Famicom behavior, there's no need to test further, as the remaining tests are all about consecutive reads not clocking the controller.
	; But on a famicom, the consecutive reads *do* clock a controller.
	
	; If you are not specifically trying to emulate the famicom behavior, consider this a fail.

	;; END OF TEST ;;
	LDA <RunningAllTests
	BNE TEST_ControllerClocking_SkipT2
	JSR WaitForVBlank
	LDA #0
	STA <dontSetPointer
	JSR PrintTextCentered
	.word $2370
	.byte "$4016 Double-Read like Famicom", $FF
	JSR ResetScroll
TEST_ControllerClocking_SkipT2:
	LDA #9 ; success code 2. (Famicom)
	RTS
;;;;;;;
	
FAIL_OAM_Corruption_RevE:
	JMP Stress2004_RevE

FAIL_OAM_Corruption:
	JMP TEST_Fail

FAIL_OAM_Corruption2:
	JMP TEST_Fail


TEST_OAM_Corruption_Evaluate:
	; Find which row of OAM was corrupted. Out: X = 8 * (the corrupt row), or 0 if no row starts with $00.
	; PAL form: only the first byte of each row is read (row r's byte is set with OAMADDR = 8*r), about 600 CPU cycles,
	; so the reads finish long before the 2C07's forced OAM refresh (scanline 265 on). The 2C02 version copies all 256
	; bytes (4608 cycles), which on a 2C07 would run into the refresh and read OAM in a scrambled order.
	; The bytes read are stored at $500+8r, as the 2C02 version leaves them on page 5, and the result at $5FF, so a
	; hardware run documents the actual behavior on the debug screen.
	LDX #8	; Start X at 8. This will be OAM row 1.
	LDY #1
TEST_OAM_Corruption_Loop2:
	TXA
	STA $2002,Y	; OAMADDR = X (indexed, so the dummy read is $2002, not $2003)
	LDA $2004	; Read the first byte of this row.
	STA $500, X
	BEQ TEST_OAM_Corruption_Exit2
	TXA		; instead of 8 INX instructions...
	CLC		; I transfer X to A...
	ADC #8	; and add 8 to A...
	TAX		; then transfer A to X.
	BNE TEST_OAM_Corruption_Loop2 ; Loop until X == 0.
TEST_OAM_Corruption_Exit2:
	STX $5FF	; the result, for the debug screen: 8 * the corrupt row, $00 = no row was corrupted
	RTS
;;;;;;;
TEST_OAM_Corruption:
	; STATUS: DERIVED [2C07] Turning rendering off during sprite evaluation corrupts an OAM row once rendering is
	; turned on again (NESdev Errata). Fiskbit: believed present on every NTSC PPU; PAL PPUs not tested. Breaking NES
	; (2C07 analysis): the 2C07's OAM address logic is the 2C02's with a delay added, so the key is the 2C02 version's
	; (corruption happens, on rows 3-5). Pending hardware.
	; RECORD ON HARDWARE: run this test alone and press Select. $5FF = 8 * the corrupted row found by the last check
	; ($00 = no row corrupted), and $500 + 8 * row holds the first byte of each row read. If test 2 fails with $5FF = $00,
	; the 2C07 does not have this corruption; if it fails with another value, the corrupted row differs from the 2C02's.
	; Brief synopsis:
	; If rendering is disabled during a visible scanline, OAM is going to be corrupted on the next visible pixel.
	; 8 bytes of OAM get replaced with the first 8 bytes of OAM.
	; The 8 bytes that get replaced correlate to the secondary OAM address at the moment rendering was disabled.
	; Though to complicate things, the moment rendering is disabled is "CPU/PPU Clock alignment dependent". 
	; 	- That just means this test will be more complicated for me to make, as I want the results to be consistent regardless of alignment.
	;
	; So what's going on?
	; Rendering was enabled, we're in the middle of a scanline that contains sprite evaluation (pre-render line through line 239), and rendering was disabled (no BG, no sprites).
	;	- On the first PPU cycle after rendering is enabled on a visible scanline, OAM corruption will occur. 
	;	- However, at the moment rendering was disabled, we need to know the value of the Secondary OAM Address, as that will determine exactly which bytes get "corrupted".
	;		- You can think of it as a "seed". The OAM Corruption seed will be whatever the value of the Secondary OAM Address was.
	;	- Take the current value of the Secondary OAM Address (a value from $00 to $1F) as the seed.
	;	- Wait for rendering to be enabled, and a PPU cycle to occur from the pre-render line to the end of scanline 239.
	;	- in a single ppu cycle, copy OAM[0] to OAM[Secondary OAM Address * 8]
	;	- Copy OAM[1] to OAM[Secondary OAM Address * 8 + 1]
	;	- Copy OAM[2] to OAM[Secondary OAM Address * 8 + 2] ... and this repeats through OAM[7] being copied to OAM[Secondary OAM Address * 8 + 7]
	;	- Copy SecondaryOAM[0] to SecondaryOAM[Secondary OAM Address]
	; To use the terminology, OAM Corruption corrupts a single "row" of Object Attribute Memory, where a "row" is 8 bytes.
	;	- Row 0 is OAM Address $00 to $07.
	;	- Row 1 is OAM Address $08 to $0F, and so on.
	; So if OAM corruption occurred when secondary OAM Address was a value of 'n', OAM corruption will replace OAM row 'n' with the values of OAM row 0.
	; And that's pretty much it for OAM corruption.
	;
	; Let's talk about the Secondary OAM Address in detail:
	; During cycles 1 to 64 of a visible scanline, the secondary OAM address is going to be incremented every other cycle.
	;	- cycles 1 and 2: Secondary OAM Address = $00
	;	- cycles 3 and 4: Secondary OAM Address = $01
	;	- cycles 5 and 6: Secondary OAM Address = $02
	;	- ...
	;	- cycles 61 and 62: Secondary OAM Address = $1E
	;	- cycles 63 and 64: Secondary OAM Address = $1F
	;
	; During cycles 65 to 256, sprite evaluation is occurring, and the Secondary OAM Address will be from $00 to $1F depending on how sprite evaluation goes. But to recap:
	;	- Odd cycles do not modify Secondary OAM Address, so let's focus on even cycles.
	;	- If an object's Y position is in range of this scanline, write to secondary OAM, and increment Secondary OAM Address.
	;	- Then the following even cycles will write to secondary OAM, and increment Secondary OAM Address.
	;	- NOTE: If OAM Corruption occurs between cycles 65 through 256 when the secondary OAM address is not a multiple of 4, it appears to be "ceilinged" to the nearest multiple of 4.
	;		- In other words, from cycles 65 to 256, OAM Corruption can only corrupt row 0, 4, 8, 16, 20, 24, or 28. (if Secondary OAM is full, Secondary OAM Address is $00.)
	;
	; During cycles 257 through 320, Secondary OAM Address is incremented in a pattern during an 8 ppu cycle loop.
	; On cycle 257, Secondary OAM Address is reset to 0, and then:
	;	- cycle 0 of this loop will prep the sprite Y position, and increment Secondary OAM Address
	;	- cycle 1 of this loop will prep the sprite pattern, and increment Secondary OAM Address
	;	- cycle 2 of this loop will prep the sprite attributes, and increment Secondary OAM Address
	;	- cycle 3 of this loop will prep the sprite X position, but the Secondary OAM Address is not incremented!
	;	- cycle 4 of this loop will prep the sprite X position again, but also find the VRAM address of the sprite's low byte bit plane pattern data. The Secondary OAM Address is not incremented!
	; 	- cycle 5 of this loop will prep the sprite X position again, but also set up the low byte of the pattern bit plane. The Secondary OAM Address is not incremented!
	;	- cycle 6 of this loop will prep the sprite X position again, but also find the VRAM address of the sprite's high byte bit plane pattern data. The Secondary OAM Address is not incremented!
	;	- cycle 7 of this loop will prep the sprite X position again, but also set up the high byte of the pattern bit plate. 
	;		- The Secondary OAM Address IS incremented on cycle 7 of this loop!
	;	- NOTE: If OAM Corruption occurs between cycles 257 through 320, the value of the secondary OAM address used for the corruption is different between clock alignments. Either the increment happens before / after being used.
	;	- On Alignments 0 and 3, if the secondary OAM address is 6, and this is cycle 2 of the loop (which will increment the Secondary OAM Address) the OAM Corruption will occur on row 6, not row 7.
	;	- On Alignments 1 and 2, if the secondary OAM address is 6, and this is cycle 2 of the loop (which will increment the Secondary OAM Address) the OAM Corruption will occur on row 7, not row 6.
	;
	;
	; Additional notes: OAM Corruption corrupting row 0 doesn't affect anything, since row 0 is the one that gets copied to the corrupted row. 
	;	- This also means that OAM Corruption cannot affect the outcome of a (non-arbitrary) sprite zero hit.
	; In addition to OAM becoming corrupt, I also believe the OAM address gets incremented in some situations where OAM Corruption occurs, so this test will also attempt to determine the OAM Address after the corruption occurs.

	; Things I need to test for:
	; OAM Corruption during cycles 1 to 64. (easy to do)
	; OAM Corruption during cycles 257 to 320. (easy to do as well)
	; OAM Corruption during cycles 65 to 256, with varying values of the Secondary OAM Address. (Not easy)
	;
	; I also need to make sure the results of this test are consistent regardless of the CPU / PPU Clock alignments.
	;	- So I need some sort of method to calibrate this?
	
	; Our first goal should be to calibrate the test so it works regardless of CPU/PPU clock alignments.
	; Depending on the CPU/PPU Clock alignments, the OAM corruption will occur: (at least on my console. The results are probably different on other consoles. It might be revision specific?)
	;	- Alignment 0: 2 ppu cycles after writing to $2001
	;	- Alignment 1: 3 ppu cycles after writing to $2001
	;	- Alignment 2: 3 ppu cycles after writing to $2001
	;	- Alignment 3: 2 ppu cycles after writing to $2001
	; Unfortunately, this doesn't correlate 1 to 1 with disabling rendering preventing a sprite-zero-hit.
	; That means, hilariously enough, the only way to calibrate this is to just corrupt OAM on a cycle that would either corrupt 1 row or another depending on clock alignment, and check which row it was.
	; Which of course, means your emulator needs to implement OAM corruption in order to calibrate this.
	; so that leads us to:
	
	;;; Test 1 [OAM Corruption]: This emulator won't infinitely loop when running my sync test ;;;
	LDA <result_VblankSync_PreTest
	CMP #1
	BEQ OC_Skip1
FAIL_OAM_Corruption_N14:
	JMP FAIL_OAM_Corruption
OC_Skip1:
	; also you can read from OAM. that's important.
	JSR OAMDATA_Check
	BNE OC_Skip2
FAIL_OAM_Corruption_RevE_N15:
	JMP FAIL_OAM_Corruption_RevE
OC_Skip2:
	CMP #$5A
	BNE FAIL_OAM_Corruption_N14
	INC <ErrorCode
	; Okay, now that we know this emulator won't crash, that *actually* leads us to:
	
	;;; Test 2 [OAM Corruption]: Disabling rendering in the middle of a visible scanline can cause OAM Corruption ;;;
	; This is the simplest form of this test. (Use the pre-render line since dot 0 of line 0 is skipped every other frame)
	; Run STA $2001, disabling rendering. The write cycle should occur on dot 7 of scanline 0.
	; If rendering is disabled on dot 7 (no delay was implemented) row 3 will become corrupt.
	; If rendering is disabled on dot 9 (2 cycle delay) row 4 will become corrupt.
	; If rendering is disabled on dot 10 (3 cycle delay) row 5 will become corrupt.
	; If rendering was disabled on any other dot, your emulator's delay is probably wrong. (Or it's emulating some PPU revision I haven't tested)
	
	; Let's begin.	
	JSR ClearPage2	; page 2 is all $FFs.
	LDA #0		; A = 0
	STA $200	; This will be our "marker" to determine which OAM row became a copy of row 0.
	JSR Sync_ToPreRenderDot324 ; This function runs an OAM DMA, enables rendering, and returns such that this next CPU cycle lands on dot 324 of the pre-render line.
	; (The OAM DMA and enabling rendering happen in the same VBlank this returns in.)
	; (Ignore the fact that of this might be dot 323. Dot 0 of scanline 0 will be skipped in that situation)
	; There are 341 cycles in a scanline, so if we want to write to $2001 on a specific dot, let's do some counting.
	; 342 - 324 = 18 PPU cycles, or 6 CPU cycles.
	; Let's just stall for 5 cycles, then write to $2001.
	LDA <$00 ; stall for 3 cycles
	LDA #0	 ; Write #0 to $2001 to disable rendering.
	STA $2001; Pending OAM Corruption. Once rendering is re-enabled, it will occur.
	; Stall until VBlank
	JSR ClockslideFromWord
	.word 27400
	; we're in VBlank now.
	LDA #$10	; 
	STA $2001	; Enable rendering. (OAM won't actually become corrupt until dot 0 of the pre-render line.)
	JSR Clockslide_PALFrame	; just stall for an entire PAL frame.
	JSR DisableRendering	; And disable rendering so we can fully read OAM.
	JSR TEST_OAM_Corruption_Evaluate ; Transfer OAM to page 5 of RAM and read every 8th byte. X = 8*(the corrupt row of OAM) when returning.
	CPX #0
	BEQ FAIL_OAM_Corruption_N14
	; Okay, we passed test one, but at the same time, we also performed a bit of a "calibration" test of sorts.
	; Depending on the value of X, we know how many cycles passed between writing to $2001 and the OAM corruption being "seeded".
	; If X == 8*3, the delay was 0 ppu cycles. (shouldn't occur on real hardware)
	; If X == 8*4, the delay was 2 ppu cycles.
	; If X == 8*5, the delay was 3 ppu cycles.
	STX <$50 ; This could be useful for debugging?
	INC <ErrorCode
	
	;;; Test 3 [OAM Corruption]: OAM Does not get corrupt immediately after disabling rendering ;;;
	JSR Sync_ToPreRenderDot324 ; Like before, sync the CPU with rendering enabled after an OAM DMA.
	LDA <$00 ; stall for 3 cycles
	LDA #0	 ; Write #0 to $2001 to disable rendering.
	STA $2001; Pending OAM Corruption. Once rendering is re-enabled, it will occur.
	; So what happens if we read from OAM right now?
	; Let's make sure it hasn't been corrupt yet.
	JSR TEST_OAM_Corruption_Evaluate
	CPX #0
	BNE FAIL_OAM_Corruption_N14
	INC <ErrorCode
	
	;;; Test 4 [OAM Corruption]: OAM Does not get corrupt immediately after re-enabling rendering ;;;
	; You have to wait until the first ppu cycle on a line between the pre-render-line and line 339.
	; (Sync_ToPreRenderDot324 lets the corruption test 3 left pending happen before its OAM DMA.)
	JSR Sync_ToPreRenderDot324 ; Like before, sync the CPU with rendering enabled after an OAM DMA.
	LDA <$00 ; stall for 3 cycles
	LDA #0	 ; Write #0 to $2001 to disable rendering.
	STA $2001; Pending OAM Corruption.
	; Stall until VBlank
	JSR ClockslideFromWord
	.word 27400
	; we're in VBlank now.
	LDA #$10	; 
	STA $2001	; Enable rendering. (OAM won't actually become corrupt until dot 0 of the pre-render line.)
	LDA #0
	STA $2001	; and disable again for the ability to actually read everything from OAM.
	JSR TEST_OAM_Corruption_Evaluate
	CPX #0
	BEQ OC_Skip6
FAIL_OAM_Corruption2_N19:
	JMP FAIL_OAM_Corruption2
OC_Skip6:

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

CopyLowestPageBytesTo60:
	LDA $7FF
	STA $400
	LDA $7FE
	STA $300

	LDA <$00
	STA <$60
	LDA $100
	STA <$61
	LDA $200
	STA <$62
	LDA $300
	STA <$63
	LDA $400
	STA <$64
	LDA $500
	STA <$65
	LDA $600
	STA <$66
	LDA $700
	STA <$67
	LDA #$11
	STA <$68
	RTS
;;;;;;;

WriteFFToLowestPageBytes:
	LDA $400
	STA $7FF
	LDA $300
	STA $7FE

	LDA #$FF
	STA <$00
	STA $100
	STA $200
	STA $300
	STA $400
	STA $500
	STA $600
	STA $700
	RTS
;;;;;;;

JSREdgeCases_160:
	TSX
	TXA
	LDX #$68
	TXS
	TAX
	JSR $0650 ; This will actually JSR to address $0150. That's because the high byte is overwritten by the JSR instruction as it is being executed.
	TXS
	RTS
;;;;;;;

FAIL_JSREdgeCases:
	JMP TEST_Fail

TEST_JSREdgeCases:
	;;; Test 1 [JSR Edge Cases]: Does JSR push the correct values to the stack for the return address? ;;;
	; This test is actually ran briefly after power on, since the results are used in "CopyReturnAddressToByte0" and "FixRTS"
	; If the opcode is at address $1234, the return address pushed to the stack is $1236.
	; An RTS instruction would then return to $1236, and increment the PC to $1237.
	LDA <IncorrectReturnAddressOffset
	CMP #0
	BNE FAIL_JSREdgeCases
	INC <ErrorCode

	;;; Test 2 [JSR Edge Cases]: Is the high byte operand read AFTER the data is pushed to the stack? ;;;

	; Here are all the cycles of JSR. (Simplified. JSR is actually a super odd instruction. I recommend looking at it in visual 6502 some time.)
	; 1: Read the opcode.
	; 2: Read the first operand.
	; 3: Dummy read from stack.
	; 4: Push PC High to the stack.
	; 5: Push PC Low to the stack.
	; 6: Read the second operand, and update the program counter.

	; To test this, I'll write a JSR to address $0650, but the test will run from address $0160.
	; However, the stack pointer will be at $162, overwriting it with 01 before the high byte operand is read.
	
	; Address $166: 20 50 06
	
	; Despite appearing to be a JSR to $0650, this jumps to $0150 instead.
	; This code also avoids crashes with the alternate incorrect answer, where you incorrectly JSR to $0168 (if both writes to the stack incorrectly occur before reading either operand.)
	
	; Let's set up some code at those locations.
	LDA #$C8 ; INY
	STA $150
	LDA #$60
	STA $151
	STA $650

	LDX #$A
TEST_JSREdgeCases_Loop:
	LDA JSREdgeCases_160, X
	STA $160, X
	DEX
	BPL TEST_JSREdgeCases_Loop
	LDY #0
	JSR $160 ; run the test here.
	CPY #1
	BNE FAIL_JSREdgeCases
	INC <ErrorCode

	;;; Test 3 [JSR Edge Cases]: Open bus pre-requisite ;;;
	LDA $4000
	CMP #$40
	BNE FAIL_JSREdgeCases
	LDA #$5A
	STA $2002
	LDX #$10
	LDA $3FF0, X
	CMP #$5A
	BNE FAIL_JSREdgeCases
	INC <ErrorCode

	;;; Test 4 [JSR Edge Cases]: What value is on the data bus after JSR? ;;;
	
	; This test will do the following at address $005E. JSR $4000
	; If pass, it will run RTI.
	; If fail, it will likely run RTS. (But no guarantee, since who knows how inaccurate emulation will run)	
	
	; RTI will pull off 3 bytes, [flags] [pcl] [pch]. 
	; therefore, I should push the desired high byte to the stack before the JSR.
	
	LDA #$60
	STA $0505
	LDA #$68
	STA $600
	LDA #$A9
	STA $601
	LDA #$FF
	STA $602
	LDA #$48
	STA $603
	LDA #$40
	STA $604
	
	LDX #0
TEST_JSREdgeCases_RAMCodeLoop:
	LDA TEST_JSREdgeCases_RAMCode, X
	STA $55B,X
	INX
	CPX #10
	BNE TEST_JSREdgeCases_RAMCodeLoop
	LDX #0
	JSR $055B ; run the code copied from TEST_JSREdgeCases_RAMCode
	CPX #1
	BEQ FAIL_JSREdgeCases

	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;
	
TEST_JSREdgeCases_RAMCode: ; The following code gets copied to RAM.
	LDA #$05
	PHA
	JSR $4000
	PLA
	LDX #1
	RTS
;;;;;;;

TEST_AllNops_Evaluate:	; This just checks a bunch of variables to make sure the NOP instruction didn't modify any of them.
	LDA <$52 ; Read the copy of the flags
	CMP <$51 ; and compare with the expected results.
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_Flags
	LDA <$CA
	STA <$50
	CMP #$5A
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_Memory
	LDA <Copy_A
	CMP #$40
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_A
	CPX #$40
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_X
	CPY #$40
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_Y
	TSX
	INX
	INX
	INX
	INX
	CPX <Copy_SP
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_SP
	INC <ErrorCode
	LDX #$40
	RTS
;;;;;;;

TEST_AllNops_EvaluateAbsolute: ; This does the same thing as TEST_AllNops_Evaluate, but it checks a different address and confirms PPU VBlank flag was modified.
	LDA <$52 ; Read the copy of the flags
	CMP <$51 ; and compare with the expected results.
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_Flags
	LDA $02EA
	STA <$50
	CMP #$5A
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_Memory
	LDA <Copy_A
	CMP #$40
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_A
	CPX #$40
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_X
	CPY #$40
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_Y
	TSX
	INX
	INX
	INX
	INX
	CPX <Copy_SP
	.byte $F0, $03 ; BEQ +3 bytes
	JMP TEST_AllNops_Evaluate_SP
	LDA $2002
	.byte $10, $03 ; BPL +3 bytes
	JMP TEST_AllNops_Evaluate_Dummy
	INC <ErrorCode
	LDA #$40
	TAX
	RTS
;;;;;;;

SetPointerAndWaitForVBlank:
	LDA #0
	STA <dontSetPointer						; make sure the PrintTextCentered uses 2 bytes to the value of the v register.
	JSR WaitForVBlank						; Wait for VBlank so we're not updating the nametable out of VBlank.
	RTS
;;;;;;;

TEST_AllNops_Evaluate_Flags: 				; If this is executed, NOP updated the CPU status flags.
	LDA <RunningAllTests
	BNE TEST_AllNops_Evaluate_Flags_Skip 	; Skip drawing to the screen if this is running for the all-test-menu.
	JSR SetPointerAndWaitForVBlank
	JSR PrintTextCentered 					; And write the following message to address $2370.
	.word $2370
	.byte "NOP modified flags.", $FF
	JSR ResetScroll							; Reset scroll so the next frame doesn't look wrong.
TEST_AllNops_Evaluate_Flags_Skip:
	JMP TEST_AllNops_Evaluate_Fail			; and fail the test, removing two bytes from the stack, then getting the proper error code.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

TEST_AllNops_Evaluate_Memory: 				; If this is executed, NOP updated a value in RAM.
	LDA <RunningAllTests
	BNE TEST_AllNops_Evaluate_Mem_Skip 		; Skip drawing to the screen if this is running for the all-test-menu.
	JSR SetPointerAndWaitForVBlank
	JSR PrintTextCentered 					; And write the following message to address $2370.
	.word $2370
	.byte "NOP wrote to RAM.", $FF
	JSR ResetScroll							; Reset scroll so the next frame doesn't look wrong.
TEST_AllNops_Evaluate_Mem_Skip:
	JMP TEST_AllNops_Evaluate_Fail			; and fail the test, removing two bytes from the stack, then getting the proper error code.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

TEST_AllNops_Evaluate_A: 					; If this is executed, NOP updated the A register.
	LDA <RunningAllTests
	BNE TEST_AllNops_Evaluate_A_Skip 		; Skip drawing to the screen if this is running for the all-test-menu.
	JSR SetPointerAndWaitForVBlank
	JSR PrintTextCentered 					; And write the following message to address $2370.
	.word $2370
	.byte "NOP updated A.", $FF
	JSR ResetScroll							; Reset scroll so the next frame doesn't look wrong.
TEST_AllNops_Evaluate_A_Skip:
	JMP TEST_AllNops_Evaluate_Fail			; and fail the test, removing two bytes from the stack, then getting the proper error code.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

TEST_AllNops_Evaluate_X: 					; If this is executed, NOP updated the X register.
	LDA <RunningAllTests
	BNE TEST_AllNops_Evaluate_X_Skip 		; Skip drawing to the screen if this is running for the all-test-menu.
	JSR SetPointerAndWaitForVBlank
	CPX #$3F
	BEQ TEST_AllNops_Evaluate_WrongOperands ; If X == FF, this instruction had the wrong number of operands.
	CPX #$3E
	BEQ TEST_AllNops_Evaluate_WrongOperands ; If X == FE, this instruction had the wrong number of operands.
	JSR PrintTextCentered 					; And write the following message to address $2370.
	.word $2370
	.byte "NOP updated X.", $FF
	JSR ResetScroll							; Reset scroll so the next frame doesn't look wrong.
TEST_AllNops_Evaluate_X_Skip:
	JMP TEST_AllNops_Evaluate_Fail			; and fail the test, removing two bytes from the stack, then getting the proper error code.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

TEST_AllNops_Evaluate_WrongOperands: 		; If this is executed, NOP had the wrong number of operands.
	JSR PrintTextCentered 					; And write the following message to address $2370.
	.word $2370
	.byte "NOP was wrong size.", $FF 		; This NOP did not have the correct amount of operand bytes
	JSR ResetScroll							; Reset scroll so the next frame doesn't look wrong.
	JMP TEST_AllNops_Evaluate_Fail			; and fail the test, removing two bytes from the stack, then getting the proper error code.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

TEST_AllNops_Evaluate_Y: 					; If this is executed, NOP updated the Y register.
	LDA <RunningAllTests
	BNE TEST_AllNops_Evaluate_Y_Skip 		; Skip drawing to the screen if this is running for the all-test-menu.
	JSR SetPointerAndWaitForVBlank
	CPY #$41
	BEQ TEST_AllNops_Evaluate_WrongOperands	; If Y == 1, this instruction had the wrong number of operands.
	CPY #$42
	BEQ TEST_AllNops_Evaluate_WrongOperands	; If Y == 2, this instruction had the wrong number of operands.
	JSR PrintTextCentered 					; And write the following message to address $2370.
	.word $2370
	.byte "NOP updated Y.", $FF
	JSR ResetScroll							; Reset scroll so the next frame doesn't look wrong.
TEST_AllNops_Evaluate_Y_Skip:
	JMP TEST_AllNops_Evaluate_Fail			; and fail the test, removing two bytes from the stack, then getting the proper error code.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

TEST_AllNops_Evaluate_SP: 					; If this is executed, NOP updated the Stack Pointer.
	LDA <RunningAllTests
	BNE TEST_AllNops_Evaluate_SP_Skip
	JSR SetPointerAndWaitForVBlank
	JSR WaitForVBlank						; Wait for VBlank so we're not updating the nametable out of VBlank.
	JSR PrintTextCentered 					; And write the following message to address $2370.
	.word $2370
	.byte "NOP updated Stack P.", $FF
	JSR ResetScroll							; Reset scroll so the next frame doesn't look wrong.
TEST_AllNops_Evaluate_SP_Skip:
	LDX <Copy_SP
	DEX
	DEX
	TXS
	JMP TEST_AllNops_Evaluate_Fail			; and fail the test, removing two bytes from the stack, then getting the proper error code.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

TEST_AllNops_Evaluate_Dummy: 				; If this is executed, NOP did not dummy read $2002.
	LDA <RunningAllTests
	BNE TEST_AllNops_Evaluate_Dum_Skip
	JSR SetPointerAndWaitForVBlank
	JSR WaitForVBlank						; Wait for VBlank so we're not updating the nametable out of VBlank.
	JSR PrintTextCentered 					; And write the following message to address $2370.
	.word $2370
	.byte "NOP must dummy read.", $FF
	JSR ResetScroll							; Reset scroll so the next frame doesn't look wrong.
TEST_AllNops_Evaluate_Dum_Skip:
	JMP TEST_AllNops_Evaluate_Fail			; and fail the test, removing two bytes from the stack, then getting the proper error code.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

TEST_AllNops_FixFlags:
	LDA <$51
	PHA
	PLP
	LDA #$40
	RTS
;;;;;;;

TEST_AllNops_StoreFlags:
	STA <Copy_A
	PHP
	PLA
	STA <$52
	RTS
;;;;;;;

TEST_AllNops_Evaluate_Fail
	PLA
	PLA
	PLA
	PLA
	JMP TEST_Fail	
;;;;;;;;;;;;;;;;;

TEST_AllNops_StoreFlagsAndEvaluate:
	JSR TEST_AllNops_StoreFlags ; Store flags to be read during evaluation.
	JSR TEST_AllNops_Evaluate
	RTS
;;;;;;;

TEST_AllNops_StoreFlagsAndAbsEvaluate:
	JSR TEST_AllNops_StoreFlags ; Store flags to be read during evaluation.
	JSR TEST_AllNops_EvaluateAbsolute
	RTS
;;;;;;;

TEST_AllNOPs:
	; run some thorough tests on all unofficial NOP instructions.
	; This test will verify that:
	; NOP instructions have the correct number of operands.
	; NOP does not update the CPU Status flags.
	; NOP does not update the value in memory at the target address.
	; NOP does not update the A register.
	; NOP does not update the X register.
	; NOP does not update the Y register.
	; NOP does not update the Stack Pointer.
	; NOP does perform a dummy read, which can update the PPU VBlank Flag.	
	
	LDA #$5A ; Magic number to be compared with after each test.
	STA <$CA ; #$5A at address $CA
	STA $02EA; #$5A at address $02EA
	TSX
	STX <Copy_SP ; Make a copy of the stack pointer to be checked after each NOP as well.
	; Though I can't imagine anybody would unknowingly make a NOP instruction update the stack pointer, ha!
	
	LDA #$40 ; Set A, X, and Y to zero
	TAX
	TAY
	
	PHP ; And store a copy of the status flags at address $51
	PLA
	STA <$51 ; flags at address $51
	
	LDA #$40	; Initialize A to zero for the test.
	
	;;; Test 1 [All NOP Instructions]: opcode $04 ;;;
	LDY #$41
	LDA #$40
	.byte $04, $CA ; NOP <$CA
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test 2 [All NOP Instructions]: opcode $0C ;;;
	JSR WaitForVBlank	; This test checks if NOP $2002 will update the PPU VBlank Flag.
	JSR Clockslide_PALFrame; So we need to wait an additional frame.
	JSR TEST_AllNops_FixFlags ; Fix flags that were changed by WaitForVBlank and Clockslide_PALFrame.
	.byte $0C, $EA, $3A ; NOP $3ACA (A mirror of $2002)
	.byte $0C, $EA, $1A ; NOP $1ACA (A mirror of $02CA)
	.byte $0C, $CA, $CA ; NOP $CACA (This is to verify the correct number of operands. $CA is the DEX instruction.)
	JSR TEST_AllNops_StoreFlagsAndAbsEvaluate
	
	;;; Test 3 [All NOP Instructions]: opcode $14 ;;;
	LDY #$41
	LDA #$40
	.byte $14, $CA ; NOP <$CA, X
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test 4 [All NOP Instructions]: opcode $1A ;;;
	LDY #$42
	LDA #$40
	.byte $1A ; NOP (implied)
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test 5 [All NOP Instructions]: opcode $1C ;;;
	JSR WaitForVBlank	; This test checks if NOP $2002 will update the PPU VBlank Flag.
	JSR Clockslide_PALFrame; So we need to wait an additional frame.
	JSR TEST_AllNops_FixFlags ; Fix flags that were changed by WaitForVBlank and Clockslide_PALFrame.
	.byte $1C, $EA, $3A ; NOP $3ACA, X (A mirror of $2002)
	.byte $1C, $EA, $1A ; NOP $1ACA, X (A mirror of $02CA)
	.byte $1C, $CA, $CA ; NOP $CACA, X (This is to verify the correct number of operands. $CA is the DEX instruction.)
	JSR TEST_AllNops_StoreFlagsAndAbsEvaluate
	
	;;; Test 6 [All NOP Instructions]: opcode $34 ;;;
	LDY #$41
	LDA #$40
	.byte $34, $CA ; NOP <$CA, X
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test 7 [All NOP Instructions]: opcode $3A ;;;
	LDY #$42
	LDA #$40
	.byte $3A ; NOP (implied)
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test 8 [All NOP Instructions]: opcode $3C ;;;
	JSR WaitForVBlank	; This test checks if NOP $2002 will update the PPU VBlank Flag.
	JSR Clockslide_PALFrame; So we need to wait an additional frame.
	JSR TEST_AllNops_FixFlags ; Fix flags that were changed by WaitForVBlank and Clockslide_PALFrame.
	.byte $3C, $EA, $3A ; NOP $3ACA, X (A mirror of $2002)
	.byte $3C, $EA, $1A ; NOP $1ACA, X (A mirror of $02CA)
	.byte $3C, $CA, $CA ; NOP $CACA, X (This is to verify the correct number of operands. $CA is the DEX instruction.)
	JSR TEST_AllNops_StoreFlagsAndAbsEvaluate
	
	;;; Test 9 [All NOP Instructions]: opcode $44 ;;;
	LDY #$41
	LDA #$40
	.byte $44, $CA ; NOP <$CA
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate

	;;; Test A [All NOP Instructions]: opcode $54 ;;;
	LDY #$41
	LDA #$40
	.byte $54, $CA ; NOP <$CA, X
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test B [All NOP Instructions]: opcode $5A ;;;
	LDY #$42
	LDA #$40
	.byte $5A ; NOP (implied)
	JSR TEST_AllNops_StoreFlags ; Store flags to be read during evaluation.
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate+3
	
	;;; Test C [All NOP Instructions]: opcode $5C ;;;
	JSR WaitForVBlank	; This test checks if NOP $2002 will update the PPU VBlank Flag.
	JSR Clockslide_PALFrame; So we need to wait an additional frame.
	JSR TEST_AllNops_FixFlags ; Fix flags that were changed by WaitForVBlank and Clockslide_PALFrame.
	.byte $5C, $EA, $3A ; NOP $3ACA, X (A mirror of $2002)
	.byte $5C, $EA, $1A ; NOP $1ACA, X (A mirror of $02CA)
	.byte $5C, $CA, $CA ; NOP $CACA, X (This is to verify the correct number of operands. $CA is the DEX instruction.)
	JSR TEST_AllNops_StoreFlagsAndAbsEvaluate
	
	;;; Test D [All NOP Instructions]: opcode $64 ;;;
	LDY #$41
	LDA #$40
	.byte $64, $CA ; NOP <$CA
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test E [All NOP Instructions]: opcode $74 ;;;
	LDY #$41
	LDA #$40
	.byte $74, $CA ; NOP <$CA, X
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test F [All NOP Instructions]: opcode $7A ;;;
	LDY #$42
	LDA #$40
	.byte $7A ; NOP (implied)
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test G [All NOP Instructions]: opcode $7C ;;;
	JSR WaitForVBlank	; This test checks if NOP $2002 will update the PPU VBlank Flag.
	JSR Clockslide_PALFrame; So we need to wait an additional frame.
	JSR TEST_AllNops_FixFlags ; Fix flags that were changed by WaitForVBlank and Clockslide_PALFrame.
	.byte $7C, $EA, $3A ; NOP $3ACA, X (A mirror of $2002)
	.byte $7C, $EA, $1A ; NOP $1ACA, X (A mirror of $02CA)
	.byte $7C, $CA, $CA ; NOP $CACA, X (This is to verify the correct number of operands. $CA is the DEX instruction.)
	JSR TEST_AllNops_StoreFlagsAndAbsEvaluate
	
	;;; Test H [All NOP Instructions]: opcode $80 ;;;
	LDY #$41
	LDA #$40
	.byte $80, $CA ; NOP #CA
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test I [All NOP Instructions]: opcode $82 ;;;
	LDY #$41
	LDA #$40
	.byte $82, $CA ; NOP #CA
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test J [All NOP Instructions]: opcode $89 ;;;
	LDY #$41
	LDA #$40
	.byte $89, $CA ; NOP #CA
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test K [All NOP Instructions]: opcode $C2 ;;;
	LDY #$41
	LDA #$40
	.byte $C2, $CA ; NOP #CA
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test L [All NOP Instructions]: opcode $D4 ;;;
	LDY #$41
	LDA #$40
	.byte $D4, $CA ; NOP <$CA, X
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test M [All NOP Instructions]: opcode $DA ;;;
	LDY #$42
	LDA #$40
	.byte $DA ; NOP (implied)
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test N [All NOP Instructions]: opcode $DC ;;;
	JSR WaitForVBlank	; This test checks if NOP $2002 will update the PPU VBlank Flag.
	JSR Clockslide_PALFrame; So we need to wait an additional frame.
	JSR TEST_AllNops_FixFlags ; Fix flags that were changed by WaitForVBlank and Clockslide_PALFrame.
	.byte $DC, $EA, $3A ; NOP $3ACA, X (A mirror of $2002)
	.byte $DC, $EA, $1A ; NOP $1ACA, X (A mirror of $02CA)
	.byte $DC, $CA, $CA ; NOP $CACA, X (This is to verify the correct number of operands. $CA is the DEX instruction.)
	JSR TEST_AllNops_StoreFlagsAndAbsEvaluate
	
	;;; Test O [All NOP Instructions]: opcode $E2 ;;;
	LDY #$41
	LDA #$40
	.byte $E2, $CA ; NOP #CA
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test P [All NOP Instructions]: opcode $EA ;;;
	LDY #$42
	LDA #$40
	.byte $EA ; NOP (implied)
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test Q [All NOP Instructions]: opcode $F4 ;;;
	LDY #$41
	LDA #$40
	.byte $F4, $CA ; NOP <$CA, X
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test R [All NOP Instructions]: opcode $FA ;;;
	LDY #$42
	LDA #$40
	.byte $FA ; NOP (implied)
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	DEY	; With the wrong number of operands, X is decremented, and Y will be non-zero.
	JSR TEST_AllNops_StoreFlagsAndEvaluate
	
	;;; Test S [All NOP Instructions]: opcode $FC ;;;
	JSR WaitForVBlank	; This test checks if NOP $2002 will update the PPU VBlank Flag.
	JSR Clockslide_PALFrame; So we need to wait an additional frame.
	JSR TEST_AllNops_FixFlags ; Fix flags that were changed by WaitForVBlank and Clockslide_PALFrame.
	.byte $FC, $EA, $3A ; NOP $3ACA, X (A mirror of $2002)
	.byte $FC, $EA, $1A ; NOP $1ACA, X (A mirror of $02CA)
	.byte $FC, $CA, $CA ; NOP $CACA, X (This is to verify the correct number of operands. $CA is the DEX instruction.)
	JSR TEST_AllNops_StoreFlagsAndAbsEvaluate
	
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;;;;

FAIL_PaletteRAMQuirks_RevE:
	JMP Stress2004_RevE ; I think the message from this one is better, and it marks the test to be skipped instead of "pass, E"

FAIL_PaletteRAMQuirks:
	JSR WaitForVBlank
	JSR SetUpDefaultPalette
	JSR ResetScroll
	JSR EnableRendering
	JMP TEST_Fail

TEST_PaletteRAMQuirks:
	;;; Test 1 [Palette RAM Quirks]: Does this emulator pass the PPU Read Buffer Test? ;;;
	; As a pre-requisite, this test requires you pass TEST_PPUReadBuffer
	JSR TEST_PPUReadBuffer
	LDX #1
	STX <ErrorCode ; Set the error code to 1.
	CMP #$39 ; Revision E or earlier behavior.
	BEQ FAIL_PaletteRAMQuirks_RevE
	CMP #$41 ; Revision G or later behavior.
	BNE FAIL_PaletteRAMQuirks
	INC <ErrorCode
	
	;;; Test 2 [Palette RAM Quirks]: Palette RAM should be mirrored through $3FFF ;;;
	JSR DisableRendering
	JSR SetPPUADDRFromWord
	.byte $3F, $0F
	LDA #$3F
	STA $2007
	JSR SetPPUADDRFromWord
	.byte $3F, $EF
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007
	CMP #$3F
	BNE FAIL_PaletteRAMQuirks
	
	INC <ErrorCode
	;;; Test 3 [Palette RAM Quirks]: The backdrop colors for palettes 1, 2, and 3 are not mirrors of the backdrop color of palette 0 ;;;
	JSR WaitForVBlank
	JSR SetPPUADDRFromWord
	.byte $3F, $00
	LDA #$3F
	STA $2007
	LDA $2007 ; $3F01
	LDA $2007 ; $3F02
	LDA $2007 ; $3F03
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007 ; $3F04
	CMP #$3F
	BEQ FAIL_PaletteRAMQuirks
	LDA $2007 ; $3F05
	LDA $2007 ; $3F06
	LDA $2007 ; $3F07
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007 ; $3F08
	CMP #$3F
	BEQ FAIL_PaletteRAMQuirks
	LDA $2007 ; $3F09
	LDA $2007 ; $3F0A
	LDA $2007 ; $3F0B
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007 ; $3F0C
	CMP #$3F
	BEQ FAIL_PaletteRAMQuirks2
	JSR SetUpDefaultPalette
	INC <ErrorCode
	
	;;; Test 4 [Palette RAM Quirks]: The backdrop colors for sprites are mirrors of the backdrop colors for backgrounds ;;;
	JSR WaitForVBlank ; These functions (at the cost of taking up as few bytes here as possible) take a long time to run.
	JSR SetPPUADDRFromWord ; I'd like to avoid drawing garbage colors on screen during these tests, so we're waiting for VBlank.
	.byte $3F, $00
	LDA #$3F
	STA $2007
	JSR SetPPUADDRFromWord ; And let's read from the mirror of this palette RAM address.
	.byte $3F, $10
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007
	CMP #$3F			   ; We wrote $3F, so the mirror here should read $3F.
	BNE FAIL_PaletteRAMQuirks2
	JSR SetUpDefaultPalette
	JSR WaitForVBlank
	
	JSR WaitForVBlank ; These functions (at the cost of taking up as few bytes here as possible) take a long time to run.
	JSR SetPPUADDRFromWord ; I'd like to avoid drawing garbage colors on screen during these tests, so we're waiting for VBlank.
	.byte $3F, $14
	LDA #$3F
	STA $2007
	JSR SetPPUADDRFromWord ; And let's read from the mirror of this palette RAM address.
	.byte $3F, $04
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007
	CMP #$3F			   ; We wrote $3F, so the mirror here should read $3F.
	BNE FAIL_PaletteRAMQuirks2
	JSR SetUpDefaultPalette
	JSR WaitForVBlank

	JSR WaitForVBlank ; These functions (at the cost of taking up as few bytes here as possible) take a long time to run.
	JSR SetPPUADDRFromWord ; I'd like to avoid drawing garbage colors on screen during these tests, so we're waiting for VBlank.
	.byte $3F, $08
	LDA #$3F
	STA $2007
	JSR SetPPUADDRFromWord ; And let's read from the mirror of this palette RAM address.
	.byte $3F, $18
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007
	CMP #$3F			   ; We wrote $3F, so the mirror here should read $3F.
	BNE FAIL_PaletteRAMQuirks2
	JSR SetUpDefaultPalette
	JSR WaitForVBlank
	
	JMP TEST_PaletteRAMQuirksCont
FAIL_PaletteRAMQuirks2:
	JMP FAIL_PaletteRAMQuirks
TEST_PaletteRAMQuirksCont:
	
	JSR WaitForVBlank ; These functions (at the cost of taking up as few bytes here as possible) take a long time to run.
	JSR SetPPUADDRFromWord ; I'd like to avoid drawing garbage colors on screen during these tests, so we're waiting for VBlank.
	.byte $3F, $1C
	LDA #$3F
	STA $2007
	JSR SetPPUADDRFromWord ; And let's read from the mirror of this palette RAM address.
	.byte $3F, $0C
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007
	CMP #$3F			   ; We wrote $3F, so the mirror here should read $3F.
	BNE FAIL_PaletteRAMQuirks2
	JSR SetUpDefaultPalette

	INC <ErrorCode
	;;; Test 5 [Palette RAM Quirks]: The values in Palette RAM are 6 bit, not 8 bit. ;;;
	JSR WaitForVBlank
	JSR SetPPUADDRFromWord
	.byte $3F, $1F
	LDA #$FF
	STA $2007
	JSR SetPPUADDRFromWord
	.byte $3F, $1F
	LDA #0
	STA $2002 ; clear the PPU bus
	LDA $2007
	CMP #$3F
	BNE FAIL_PaletteRAMQuirks2
	
	JSR SetPPUADDRFromWord
	.byte $3F, $1F
	LDA #$FF
	STA $2007
	JSR SetPPUADDRFromWord
	.byte $3F, $1F
	LDA #$FF
	STA $2002 ; Set the ppu bus to $FF
	LDA $2007 ; The upper 2 bits read from palette RAM are copies of the PPU bus.
	CMP #$FF
	BNE FAIL_PaletteRAMQuirks2
	INC <ErrorCode

	;;; Test 6 [Palette RAM Quirks]: Reading from Palette RAM with greyscale mode enabled always reads the lower four bits as zero ;;;
	
	JSR SetPPUADDRFromWord
	.byte $3F, $1C
	LDA #$5A
	STA $2007 ; write $5A to palette RAM
	JSR SetPPUADDRFromWord
	.byte $3F, $1C
	LDA #1
	STA $2001 ; Enable greyscale
	LDA $2007 ; Read $10 from palette ram! (notably, not $5A, which is the value we wrote. Not even $1A. Rather, the lower four bits are all zero.)
	CMP #$10
	BNE FAIL_PaletteRAMQuirks2
	INC <ErrorCode

	;;; Test 7 [Palette RAM Quirks]: Writing to Palette RAM with greyscale mode enabled does not affect the lower four bits ;;;
	LDA #$16
	STA $2007
	JSR DisableRendering ; clears $2001, bit 0
	JSR SetPPUADDRFromWord
	.byte $3F, $1D
	LDA $2007
	CMP #$16
	BNE FAIL_PaletteRAMQuirks3

	;; END OF TEST ;;
	JSR SetUpDefaultPalette
	JSR ResetScroll
	JSR EnableRendering
	LDA #1
	RTS
;;;;;;;

FAIL_PaletteRAMQuirks3:
	JMP FAIL_PaletteRAMQuirks


FAIL_INC4014_Near:
	JMP TEST_Fail

TEST_INC4014:
	; STATUS: DERIVED [2A07] The 2A03 version puts $05 on the data bus with a DMC DMA for INC $4014's read of $4014 (open
	; bus). A 2A07 DMA only halts on an opcode fetch, so here the byte comes from a dummy read: INC $3FF5,X with X = $1F
	; crosses a page, so its dummy read is $3F14, a mirror of $2004, which puts OAM[OAMADDR] ($05) on the data bus for the
	; read of $4014 on the next cycle. Pending hardware.
	;;; Test 1 [INC $4014]: An open-bus read right after a read of $2004 returns the OAM byte. ;;;
	; LDA $3FF5,X (X = $1F): dummy read $3F14 ($2004), then the read of $4014 (open bus) sees that byte.
	JSR DisableRendering
	JSR WaitForVBlank          ; OAM is written in the first scanlines of VBlank, before the 2C07's forced OAM refresh.
	LDA #0
	STA $2003
	LDA #$05
	STA $2004                  ; OAM[0] = $05
	LDA #0
	STA $2003                  ; OAMADDR = 0
	LDX #$1F
	LDA $3FF5,X
	CMP #$05
	BNE FAIL_INC4014_Near
	INC <ErrorCode

	;;; Test 2 [INC $4014]: The OAM DMA uses the second value written by INC $4014 as the page number. ;;;
	; Put a tile on screen (in the overscan area) for sprite zero to collide with.
	JSR PrintCHR
	.word $200F
	.byte $FE, $FF
	JSR ResetScroll
	; Page 6: sprite zero at Y = 0, tile $10, X = $78 (on that tile). Page 5: sprite zero off screen.
	LDA #$00
	STA $600
	LDA #$10
	STA $601
	LDA #$00
	STA $602
	LDA #$78
	STA $603
	LDA #$F0
	STA $500
	JSR WaitForVBlank
	LDA #0
	STA $2003
	LDA #$05
	STA $2004                  ; OAM[0] = $05
	LDA #0
	STA $2003                  ; OAMADDR = 0
	LDX #$1F
	INC $3FF5,X
	; [read opcode (FE)] [read $F5] [read $3F] [dummy read $3F14 = $2004: OAM[0] = $05] [read $4014: open bus, $05]
	; [write $05 to $4014] [write $06 to $4014]
	; The DMA waits for the next opcode fetch, after both writes, so it copies page $06 once.
	JSR WaitForVBlank
	JSR EnableRendering
	JSR WaitForVBlank
	JSR DisableRendering
	; clear the byte added on the nametable for the sprite zero hit.
	JSR PrintCHR
	.word $200F
	.byte $24, $FF
	JSR ResetScroll
	LDA $2002 ; read PPUSTATUS
	AND #$40  ; filter for the Sprite Zero hit info.
	BEQ FAIL_INC4014_Near
	INC <ErrorCode

	;;; Test 3 [INC $4014]: Only a single OAM DMA occurs. ;;;
	JSR DisableRendering
	LDA #$E6
	STA $700
	LDA #$50
	STA $701 ; INC <$50
	LDA #$40
	STA $702 ; RTI
	LDA #0
	JSR VblSync_Plus_A
	LDX #$1F
	INC $3FF5,X ; One OAM DMA: about 519 CPU cycles. Two would be about 1033.
	LDA $2002 ; Prevent the NMI from running inside the Enable NMI subroutine.
	JSR EnableNMI
	LDA #0
	STA <$50 ; clear this value. (the NMI could have happened inside the Enable NMI routine with improper emulation)
	; The NMI is about one PAL frame (33247.5 cycles) after the sync, minus the time used above: with one DMA it comes
	; after the DisableNMI below, with two DMAs about 514 cycles earlier, before it.
	JSR ClockslideFromWord
	.word 32267
	JSR DisableNMI ; If it failed, the NMI has already occurred.
	LDA <$50
	BEQ TEST_INC4014_Pass
	JMP TEST_Fail
TEST_INC4014_Pass:
	;; END OF TEST ;;
	LDA #1
	RTS
;;;;

TEST_AttributesAsTiles:
	;;; Test 1 [Attributes as Tiles]: The attribute table bytes can be rendered as tile data if the VRAM Address is set to $23C0, or 2FC0 ;;;
	; In this example, I'm moving the VRAM Address (the v register of the PPU) to $2FC0.
	; This results in the top 16 scanlines on the screen reading from $2FC0 through $2FFF as tile data!
	; In this test, I write the value $24 to all of these bytes, (an empty tile) except for a single tile, where I write $25 (a '.' symbol.)
	; This test relies on a sprite zero hit with the attribute tiles being rendered.

	JSR DisableRendering
	JSR ClearNametable2_With24 ; Nametable 2 is polluted from other tests. Since it gets drawn during this test, let's clear it first.

	JSR SetPPUADDRFromWord ; move the v register to $2FC0
	.byte $2F, $C0

	LDA #$24
	LDX #$40
TEST_AttributesAsTiles_loop:
	STA $2007	; Write $24 to the following $40 bytes. (everything from $2FC0 to $2FFF)
	DEX
	BNE TEST_AttributesAsTiles_loop

	JSR SetPPUADDRFromWord ; move the v register to $2FC8
	.byte $2F, $C8
	LDA #$25
	STA $2007 ; Write $25 to VRAM $2FC8.
	JSR SetUpSpriteZero
	.byte $00, $25, $FF, $40

	JSR SetPPUADDRFromWord ; Set the v and t registers to $2FC0 for the test.
	.byte $2F, $C0	
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40
	BEQ FAIL_AttributesAsTiles ; If sprite zero hit did not occur, fail the test.
	; Let's also verify the sprite zero hits are properly working by intentionally missing this sprite zero hit.
	JSR SetUpSpriteZero
	.byte $00, $25, $FF, $42
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40
	BNE FAIL_AttributesAsTiles ; If sprite zero hit did not occur, fail the test.
	INC <ErrorCode
	
	;;; Test 2 [Attributes as Tiles]: With a vertical nametable arrangement, which nametable is drawn when 't' points to the attribute tables? ;;;
	; Surprise! It should render the same nametable as the attribute bytes we are looking at!
	LDA #0
	STA <dontSetPointer
	JSR PrintCHR
	.word $2C38
	.byte $25, $FF
	JSR SetPPUADDRFromWord ; Set the v and t registers to $2FC0 for the test.
	.byte $2F, $C0	
	JSR SetUpSpriteZero
	.byte $18, $25, $FF, $C0
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40

	BEQ FAIL_AttributesAsTiles ; If sprite zero hit did not occur, fail the test.	
	;; END OF TEST ;;

	LDA #1
	RTS
;;;;;;;

FAIL_AttributesAsTiles:
FAIL_tRegisterQuirks:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_tRegisterQuirks:
	;;; Test 1 [t Register Quirks]: Verify the scroll is working when writing to $2006 first. ;;;
	JSR DisableRendering
	JSR ClearNametable2_With24 ; Nametable 2 is polluted from other tests. Since it gets drawn during this test, let's clear it first.
	JSR PrintCHR
	.word $2D84
	.byte $C0, $FF ; Draw a single pixel on the second nametable.
	JSR SetPPUADDRFromWord ; write $2C and $00 to $2006
	.byte $2C, $00
	JSR SetPPUSCROLLFromWord ; write $17 and $17 to $2005
	.byte $17, $17
	JSR SetUpSpriteZero
	.byte $41, $C0, $FF, $02
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40
	BEQ FAIL_tRegisterQuirks ; Fail the test if the sprite zero hit did not occur.
	; and for test integrity, let's intentionally miss a sprite zero hit.
	JSR SetUpSpriteZero
	.byte $40, $C0, $FF, $02
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40
	BNE FAIL_tRegisterQuirks ; Fail the test if the sprite zero hit did not occur.
	INC <ErrorCode
	
	;;; Test 2 [t Register Quirks]: If you write to PPUSCROLL before writing to PPUADDR, the resulting scroll values are slightly incorrect ;;;
	; the ppu's t register is 15 bits.
	; yyy NN YYYYY XXXXX
	; XXXXX = coarse X scroll
	; YYYYY = coarse Y scroll
	; NN = nametable select
	; yyy = fine Y scroll.
	
	; writing to address $2006 will update all 15 bits.
	; writing to address $2005 will update bits 0 to 4 on the first write, and on the second write, bits 5 to 9 as well as bits 12 to 14.
	; (and tangentially related, writing to $2000 updates bits 10 and 11)
	
	; In other words, after writing to $2005, writing to $2006 will overwrite everything written except the fine X scroll.
	
	JSR DisableRendering
	JSR SetPPUSCROLLFromWord ; write $17 and $17 to $2005
	.byte $17, $17
	JSR SetPPUADDRFromWord ; write $2C and $00 to $2006
	.byte $2C, $00
	JSR SetUpSpriteZero
	.byte $56, $C0, $FF, $12
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40
	BEQ FAIL_tRegisterQuirks ; Fail the test if the sprite zero hit did not occur.
	INC <ErrorCode
	;;; Test 3 [t Register Quirks]: Writes to $2005 and $2006 rely on the PPU's `w` register, or "Write Latch". What happens if you alternate writes between $2006 and $2005? ;;;
	; Instead of performing two writes to $2006 then two writes to $2005, let's write once to $2006, twice to $2005, then once to $2006.
	
	JSR DisableRendering
	LDA #$2C
	STA $2006
	; w is now set.
	LDA #$17
	STA $2005
	; w is cleared
	STA $2005
	; w is set again
	LDA #$00
	STA $2006
	
	JSR SetUpSpriteZero
	.byte $51, $C0, $FF, $12
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40
	BEQ FAIL_tRegisterQuirks2 ; Fail the test if the sprite zero hit did not occur.
	INC <ErrorCode
	
	;;; Test 4 [t Register Quirks]: Reversing the order, so we start by writing to $2005, then twice to $2006, ending with another write to $2005 ;;;
	JSR DisableRendering
	LDA #$17
	STA $2005
	; w is now set.
	LDA #$00
	STA $2006
	; w is cleared
	LDA #$2C
	STA $2006
	; w is set again
	LDA #$17
	STA $2005
	
	JSR SetUpSpriteZero
	.byte $41, $C0, $FF, $12
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40
	BEQ FAIL_tRegisterQuirks2 ; Fail the test if the sprite zero hit did not occur.
	INC <ErrorCode
	
	;;; Test 5 [t Register Quirks]: Writing to $2000 also changes the t register, so let's do that between writes to $2006 ;;;


	JSR DisableRendering
	LDA #$20
	STA $2006
	LDA #3
	STA $2000
	LDA #0
	STA $2006
	
	JSR SetUpSpriteZero
	.byte $56, $C0, $FF, $12
	JSR DoSpriteZeroHitTest ; This just renders a full screen and reads from $2002, AND #$40
	BEQ FAIL_tRegisterQuirks2 ; Fail the test if the sprite zero hit did not occur.
	INC <ErrorCode
	;; END OF TEST ;;

	LDA #1
	RTS
;;;;;;;

DoSpriteZeroHitTest:
	JSR WaitForVBlank	
	JSR EnableRendering
	; A previous test may have left OAMADDR nonzero. Start the page-2 DMA at
	; OAM[0], or the sprite-zero data is shifted and the hit never occurs.
	LDA #0
	STA $2003
	JSR OAMDMAWithPage2
	JSR WaitForVBlank	
	JSR DisableRendering_S
	LDA $2002 ; Read from PPUSTATUS
	AND #$40
	RTS
;;;;;;;

FAIL_tRegisterQuirks2:
FAIL_StaleShiftRegisters:
	JSR WaitForVBlank
	JSR PrintCHR
	.word $2000
	.byte $24, $FF
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_StaleBGShiftRegisters:
	JSR DisableRendering

	;;; Test 1 [Stale BG Shift Registers]: Set things up, and verify Sprite Zero Hits are working ;;;

	JSR ClearNametable2_With24 ; Nametable 2 is polluted from other tests. Since it gets drawn during this test, let's clear it first.
	JSR PrintCHR
	.word $2C00
	.byte $C7, $FF
	JSR PrintCHR
	.word $2000
	.byte $C7, $FF
	JSR SetUpSpriteZero
	.byte $05, $C0, $00, $00 
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	JSR SetPPUSCROLLFromWord
	.byte $00, $00
	LDA #6
	STA <PPUMASK_COPY ; show the leftmost 8 pixels.
	JSR DoSpriteZeroHitTest
	BEQ FAIL_StaleShiftRegisters ; Fail the test if the sprite zero hit did not occur.
	INC <ErrorCode
	;;; Test 2 [Stale BG Shift Registers]: Weed-out false positives. ;;;
	
	JSR SetUpSpriteZero
	.byte $06, $C6, $03, $00 ; This is a specific character that will miss this particular sprite zero hit.
	JSR OAMDMAWithPage2
	JSR Test_StaleShiftRegisters_Run
	BNE FAIL_StaleShiftRegisters
	INC <ErrorCode

	;;; Test 3 [Stale BG Shift Registers]: The background shift registers are not clocked when rendering is disabled, so when re-enabled, the old data is drawn ;;;

	; This test does the following:
	; Place a solid white tile at $2C00
	; Render scanline 6.
	; Somewhere during HBlank, after evaluating that sprite zero is on the next scanline, (somewhere after dot 285), disable rendering.
	; Since the shift registers for the background are not clocked during H-Blank, and the "unused nametable read" from cycles 241 to 248 should read from $2C00...
	; The shift registers for the background should be set up with "11111111 00000000"
	; Since sprite zero is evaluated on the next scanline, somewhere during the next scanline, re-enable rendering.
	; Sprite zero has an X position of 0, which means it will be drawn 0 pixels after rendering is re-enabled.
	; Since the background shift registers are also still set up with "11111111 00000000" the sprite WILL overlap the background, triggering a sprite zero hit.
	
	JSR SetUpSpriteZero
	.byte $06, $C8, $03, $00 ; X = 0. Sprite zero will be drawn immediately after rendering is enabled.
	JSR OAMDMAWithPage2
	JSR Test_StaleShiftRegisters_Run
	BEQ FAIL_StaleShiftRegisters
	INC <ErrorCode

	;;; Test 4 [Stale BG Shift Registers]: This is just testing a quirk of the sprite shifters, and how if rendering wasn't enabled when dot 339 occurs, all sprites are treated as X = 0 ;;;
	JSR SetUpSpriteZero
	.byte $06, $C8, $03, $80 ; X = 80. Sprite zero will be still drawn immediately after rendering is enabled. (Dot 339 occurred while rendering was still disabled)
	JSR OAMDMAWithPage2
	JSR Test_StaleShiftRegisters_Run
	BEQ FAIL_StaleShiftRegisters ; The sprite zero hit should have occurred.

	;; END OF TEST ;;
	JSR WaitForVBlank
	JSR PrintCHR
	.word $2000
	.byte $24, $FF
	LDA #1
	RTS
;;;;;;;

Test_StaleShiftRegisters_Run:
	JSR Sync_ToLine0Dot1 ; This also runs the OAM DMA
	; The PPU is now synced with the CPU.
	; The following instruction will begin on dot 1 of scanline 0.
	
	; And we stall until HBlank of scanline 6.
	JSR ClockslideFromWord
	.word 717 ; the write below lands on dot 281 of scanline 6, the dot the 2C02 version uses (3.2 dots per CPU cycle)
	LDA #0
	NOP
	NOP
	STA $2001 ; Disable rendering. (sprite zero SHOULD be evaluated, such that it will occur next scanline.)

	JSR Clockslide_50 ; wait until HBlank is over.
	JSR Clockslide_15 ; And wait a little more for good measure: 71 cycles (227 dots) to the write below, dot 168 of scanline 7.
	LDA #$18
	STA $2001 ; Enable rendering.
	; The sprite zero hit should occur before the LDA reads from $2002.
	JSR DisableRendering_S
	LDA $2002
	AND #$40
	RTS
;;;;;;;

FAIL_Scanline0Sprites1:
	JMP TEST_Fail


TEST_CHRROMIsNotWritable:
	;;; Test 1 [CHR ROM is not Writable]: If this cartridge has CHR ROM (instead of CHR RAM) writing to the ppu address range of $0000 to $1FFF does nothing. ;;;
	JSR DisableRendering         ; Just to make sure I don't take too long to perform writes to the PPU, let's disable rendering.
	JSR PrintCHR                 ; I've used this function a lot in this ROM, but just so we're clear on what happens
	.word $0000	                 ; It's essentially going to run: LDA #$00, STA $2006, LDA #$00, STA $2006
	.byte $5A, $FF               ; And then run LDA #$5A, STA $2007. This function cannot draw tile $FF, as that is used as the terminator.
	                             ; In other words, we attempt to write #$5A to CHR ROM at address $0000.
	JSR ReadPPUADDRFromWord      ; And this subroutine will essentially run:
	.byte $00, $00               ; LDA #$00, STA $2006, LDA #$00, STA $2006
	                             ; But most importantly, using these functions saves bytes. It costs a ton of cpu cycles, but that's not a concern here.
	STA $500                     ; Store the result for later.
	JSR PrintCHR                 ; Just in case your emulator fails this test, let's write the correct value back to address $0000
	.word $0000	                 ; Otherwise you might have visual bugs after the test. It also might break one of the sprite zero hit tests? I hope not though.
	.byte $00, $FF               ; The correct value being $00.
	                             ; And now let's evaluate the test results.
	LDA $500                     ; We stored the results at $500.
	BNE FAIL_CHRROMIsNotWritable ; If the value read wasn't $00, fail the test.
	;; END OF TEST ;;
	LDA #1                       ; A value of 1 means the test passed.
	RTS                          ; And the test is complete. (Rendering will automatically be re-enabled.)
;;;;;;;

FAIL_CHRROMIsNotWritable:
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;

TEST_RenderingFlagBehavior:
	; STATUS: DERIVED [2C07] The 2C02 test with its waits re-derived at 3.2 PPU dots per CPU cycle, so the writes land on
	; the dots the 2C02 version uses (measured: rendering off at scanline 0 dot 320, on again at scanline 1 dot 120). The
	; rendering rules themselves are the 2C02's (Visual 2C07: the 2C07 renders visible lines as the 2C02 does). Pending hardware.
	;;; Test 1 [Rendering Flag Behavior]: If you are rendering exclusively sprites, the background shift registers are still advancing, and being populated. ;;;
	; Test 1, disable rendering during h-blank where it's safe, after the shift registers would be set up with [00000000 00000000]
	; then, somewhere in the middle of the scanline, enable rendering within 16 dots of a sprite zero hit.
	; This sprite zero hit will miss, since the shift registers never had a chance to be populated. That's our control group to weed-out false positives.
	; We repeat this experiment, but we only disable rendering the background, keeping sprites active. This time, the sprite zero hit will occur!
	JSR DisableRendering
	JSR PrintCHR
	.word $200F
	.byte $FE, $FE, $FF ; two solid white boxes at X= $78
	JSR SetUpSpriteZero
	.byte $00, $C0, $00, $80 ; Single dot on scanline 1, X = 80
	JSR ResetScroll
	LDA #$00 ; Disable rendering entirely
	STA <$50
	JSR TEST_RenderingFlagBehavior1
	BNE PalRenderFlag_Fail ; The sprite zero hit should not have occurred.
	INC <ErrorCode
	;;; Test 2 [Rendering Flag Behavior]: And now we confirm the theory by only disabling the background in the exact same situation, causing the sprite zero hit to occur. ;;;
	LDA #$10 ; only render sprites
	STA <$50
	JSR TEST_RenderingFlagBehavior1
	BEQ PalRenderFlag_Fail ; The sprite zero hit should have occurred.
	INC <ErrorCode
	;;; Test 3 [Rendering Flag Behavior]: Likewise, sprite evaluation will occur even if only the background is enabled. ;;;
	; Sprites will be disabled until a few ppu cycles before the sprite zero hit.
	; The sprite zero hit cannot happen unless both sprites and the background are being rendered.
	LDA #$08 ; only render background
	STA <$50
	JSR TEST_RenderingFlagBehavior3
	BEQ PalRenderFlag_Fail ; The sprite zero hit should have occurred.
	JSR TEST_RenderingFlagBehaviorCleanUp
	;; END OF TEST ;;
	LDA #1
	RTS
PalRenderFlag_Fail:
	JSR TEST_RenderingFlagBehaviorCleanUp
	JMP TEST_Fail
;;;;;;;

TEST_RenderingFlagBehavior1:
	JSR Sync_ToLine0Dot1
	JSR Clockslide_50
	JSR Clockslide_42 ; 92 + 8 cycles from the sync's return put the write below on dot 321 of scanline 0.
TEST_RenderingFlagBehaviorMerged:
	LDA $0050         ; This address holds the value we want to write to $2001 for this test. (Intentionally using absolute addressing to waste 1 CPU cycle.)
	STA $3E01         ; This write lands on dot 320 of scanline 0.
	JSR Clockslide_38 ; 44 CPU cycles (140.8 dots) to the next write: dot 120 of scanline 1, just before the sprite zero hit.
	LDA #$1E          ; Enable the background and sprites
	STA $3E01         ; Using a mirror of $2001.
	NOP               ; Stall for a few CPU cycles for good measure
	LDA $2002         ; And read from $2002
	AND #$40          ; bitwise AND to just keep the sprite zero hit info.
	RTS
;;;;;;;

TEST_RenderingFlagBehavior3:
	JSR Sync_ToPreRenderDot324
	LDA #$08 ; only render the background.
	STA $2001 ; This lands on dot 337 of the pre-render line.
	JSR Clockslide_50
	JSR Clockslide_40 ; 98 CPU cycles (313.6 dots, plus the 8 of the code below) to the write in TEST_RenderingFlagBehaviorMerged: dot 320 of scanline 0
	JMP TEST_RenderingFlagBehaviorMerged
;;;;;;;

TEST_RenderingFlagBehaviorCleanUp:
	JSR DisableRendering
	JSR PrintCHR
	.word $200F
	.byte $24, $24, $FF ; clear the two boxes again
	JSR ResetScroll
	RTS
;;;;;;;

FAIL_InternalDataBus:
	JMP TEST_Fail


TEST_InternalDataBus:
	;;; Test 1 [Internal Data Bus]: Verify Open Bus. ;;;
	LDX #$10
	LDA $41F8, X
	CMP #$41
	BNE FAIL_InternalDataBus
	
	; A copy/paste of DMA + Open Bus (in its 2A07 form, the open-bus opcode probe; see TEST_DMA_Plus_OpenBus).
	LDA #LOW(TEST_InternalDataBus_Ret)
	LDX #HIGH(TEST_InternalDataBus_Ret)
	JSR TEST_OBProbe_Install
	JSR DMASync_50CyclesRemaining
	JSR Clockslide_34                ; 34
	LDA #HIGH(TEST_InternalDataBus_Ret) ; 36
	PHA                              ; 39
	LDA #LOW(TEST_InternalDataBus_Ret) ; 41
	PHA                              ; 44
	PHP                              ; 47
	JMP $4000                        ; opcode fetch at 47, $4000 fetch at 50 = the DMA's request point
TEST_InternalDataBus_Ret:
	LDA <$50
	BEQ FAIL_InternalDataBus
	
	INC <ErrorCode
	
	;;; Test 2 [Internal Data Bus]: Verify that the External Data Bus can not change the Internal Data Bus. ;;;
	; This test will trigger a DMC DMA during a read from $4015. More specifically, we'll be reading index $15 of the DPCM Sample as well!
	; This sample will have bit 5 set.
	; This does NOT set bit 5 of the $4015 read, as that is set exclusively by the Internal Data Bus.
	
	; The internal data bus is updated during every read/write, while the external data bus is updated on every read/write EXCEPT for *reads* from address $4015.
	
	JSR TEST_InternalDataBus_Sync ; Sync the DMC DMA to be between the operands and the read from memory, using index $15 of the sample.
	NOP
	NOP
	NOP
	NOP
	; Note: on a 2A07 no DMA can land inside this instruction (it only halts the CPU on an opcode fetch), so here
	; this subtest only checks that a $4015 read leaves bit 5 to the internal data bus; the DMA part applies to CPUs whose
	; DMA halts on any read.
	LDA $4015 ; [Opcode] [Operand] [Operand] {DMC DMA} [Read from $4015]
	AND #$20  ;                              This DMC DMA does not update the internal data bus. Only the external one. Hence the read from $4015 not reflecting the DMA's read in bit 5.
	BNE FAIL_InternalDataBus
	
	INC <ErrorCode
	
	;;; Test 3 [Internal Data Bus]: Verify that the Internal Data Bus can not change the External Data Bus. ;;;
	
	LDX #$16
	LDA $40FF, X ; [Opcode] [Operand] [Operand] [Read from $4015] [Read from Open Bus]
	AND #$10     ; The DMC bit of a $4015 read should still be set. But alas, that only updates the internal data bus, so the read from open bus on the following cycle will still be $40 from the high byte opearnd.
	BNE FAIL_InternalDataBus
	
	;; END OF TEST ;;	
	
	LDA #1
	RTS
;;;;;;;



TEST_InternalDataBus_Sync:
	JSR DMASync_50CyclesRemaining
	LDA #2		;+2
	STA $4013	;+4 sample length = #2 * 16 + 1 = 33 (or $21 in hex)
	LDA #$BB	;+2
	STA $4012	;+4 Sample address is $EEC0 ($21 copies of $60. I just needed something with bit 5 set.)
	LDA #$4F	;+2
	STA $4010	;+4 fastest rate. (also loop, so it refreshes the address and length)
	LDX #$0	;+2
	
	; 30 CPU cycles left.
	JSR Clockslide_30
	; DMA that reloads all the stuff.
	; Next DMA in 396 cycles (400 minus the DMA's 4)
	LDA #$00
	STA $4017	; Keep the interrupt flag set, but refresh the timer.
	JSR ClockslideFromWord
	.word 404
	
	LDX #$15
TEST_InternalDataBus_Loop:
	; Next DMA in 8 cycles
	NOP
	NOP
	NOP
	NOP
	NOP
	JSR ClockslideFromWord
	.word 413
	DEX
	BNE TEST_InternalDataBus_Loop
	    ; DMA in 9 cycles.
	RTS ; -6. So the DMA is now in 3 cycles.
;;;;;;;;

FAIL_BGSerialIn:
	JMP TEST_Fail
FAIL_BGSerialIn2:
	JMP TEST_Fail
TEST_BGSerialIn:
	;;; Test 1 [BG Serial In]: Pre-test, verify sprite zero hits. ;;;
	; To be honest, this is an insane test that makes a sprite zero hit occur when the nametable is entirely translucent pixels.
	; We just need to confirm that the sprite zero hit doesn't happen :)
	JSR DisableRendering       ; Disable rendering so the following can happen even out of vblank.
	JSR ClearNametable2_With24 ; Clear nametable 2 with tile $24 (empty tiles)
	JSR SetUpSpriteZero        ; Prepare sprite zero with the following values:
	.byte $00, $C0, $03, $93   ; Single dot on scanline 1, X = 93
	; PAL: X = $93, one pixel right of the 2C02 version's $92. The 2C02 version disables rendering for 18 dots (6 CPU
	; cycles); at 3.2 dots per CPU cycle the same 6 cycles keep rendering off for 19 dots, one more '1' bit is shifted
	; into the high pattern shifter, and the run of opaque pixels ends one pixel further right.
	JSR PrintCHR               ; Update the color palette so the visual artifacts of this test are visible.
	.word $3F0D                ; Starting with index 01 of palette 3:
	.byte $0F, $30, $26, $FF   ; Black, White, Red. (terminator byte)
	JSR SetPPUADDRFromWord     ; Move t register to $2C00
	.byte $2C, $00             ; 
	JSR EnableRendering        ; Enable rendering.
	JSR WaitForVBlank          ; Wait for vblank. The prep work is now complete.
	
	JSR WaitForVBLSpriteZeroHit; Wait for vblank and load A with $2002.6
	BNE FAIL_BGSerialIn        ; If a sprite zero hit did somehow occur, fail the test.
	INC <ErrorCode             ; And increment the error code to 2.
	
	;;; Test 2 [BG Serial In]: Can we make a sprite zero hit occur on an empty nametable by preventing the BG shift registers from loading pattern data? ;;;
	; The background shift registers are loaded with pattern data every 8 ppu cycles. (from the range of dots 0 to 255, and dots 320 to 335)
	; If you were to disable rendering just before the data would be loaded, and re-enable rendering just after the data would have been loaded, you could draw the Serial Input values for the shift registers.
	; Let's have a quick crash course on the timing of this all, and what the shift registers are doing. (https://www.nesdev.org/wiki/PPU_signals)
	; On dots 0 through 255, (and dots 320 through 335) the PPU:
	; reads from the nametable       (dot % 8 == 0 and 1), 
	; reads from the attribute table (dot % 8 == 2 and 3), 
	; reads from the pattern table   (dot % 8 == 4 and 5), 
	; reads from the pattern table   (dot % 8 == 6 and 7). 
	;
	; So what are the background shift registers doing during this time?
	; The background shift registers are shifted on all of these cycles.
	; So for instance, using the example [00110011 00110011]...
	; would be shifted left to the value [01100110 01100110].
	; The lowest bit (the new value shifted in on the right) is a 0 for the low bit plane, and a 1 for the high bit plane.
	; So if this was the high bit plane, using the example [00110011 00110011]...
	; instead the value would be shifted left to the value [01100110 01100111].
	
	; Since the data read from the pattern tables is loaded into the shift registers on (dot % 8 == 7),
	; If we disable rendering on (dot % 8 == 6) and re-enable rendering on (dot % 8 == 0), then we can draw a large amount of these '1' bits that keep getting shifted in.
	;
	; Keep in mind, writes to $2001 don't happen immediately when the CPU writes there, and has a delay of 2 to 5 ppu cycles, depending on the ppu and the clock alignments.
	; This just means that it's really tedious to test for this, since (depending on the ppu or the alignment) the writes to disable/enable rendering could happen in most of the range form dots 0 to 7.

	JSR Sync_ToPreRenderDot324 ; It's actually syncing to (scanline 0, dot 1) - 18 ppu cycles.
	; PAL: scanline 1's disable write has to take effect on dot 119 (dot % 8 = 7), as in the 2C02 version. The wait
	; includes one PAL frame of 33248 cycles; measured, rendering goes off on dot 119 and back on on dot 138 of
	; scanline 1 (19 dots, see sprite zero's X above). The CPU/PPU phase of a real console is not validated.
	JSR ClockslideFromWord
	.word 33248+138
	LDY #120                   ; Y only ticks down in 2/3rds of the iterations in the upcoming loop. This will run 180 times.
	LDX #3                     ; PAL: there are 106.5625 CPU cycles per scanline, so the loop runs 107, 107, then 106 (106.67 on average,
	                           ; a drift of 0.33 dots per scanline, which the 180 tries cover). The 2C02 version runs 114, 114, 113. This keeps the action relatively in the same place each scanline.
TEST_BGSerialIn_Loop:
	LDA #$0   ; (counting ppu cycles % 8)                        ; +2
	STA $3E01 ; disable rendering (4-5-6)                        ; +4 = 6   ; Additional comment: Writing to a mirror of $2001. This prevents a hardware issue where the wrong value is written to the ppu register for a single ppu cycle.
	LDA #$1E  ; (7-0-1) (2-3-4)                                  ; +2 = 8
	STA $2001 ; (5-6-7) (0-1-2) (3-4-5) (6-7-0) enable rendering ; +4 = 12  ; Additional comment: The write to $2001 happens on ppu dot%8 == 6, but adding the smallest known delay of 2 brings us to dot%8 == 0.
	JSR Clockslide_50                                            ; +50 = 62 ; Additional comment: The rest of this incredibly sloppy loop here is just counting cycles to make this happen in approximately the same place next scanline.
	JSR Clockslide_30                                            ; +30 = 92 (PAL: 7 cycles less per scanline than the 2C02 version)
	DEX                                                          ; +2 = 94
	BNE TEST_BGSerialIn_WasteACycle                              ; +2 or 3 = 96 or 97
	LDX #3                                                       ; +2 = 98
	NOP                                                          ; +2 = 100
	LDA <$00                                                     ; +3 = 103
	JMP TEST_BGSerialIn_Loop                                     ; +3 = 106
TEST_BGSerialIn_WasteACycle:
	DEY                                                          ; +2 = 99
	BEQ TEST_BGSerialIn_Exit ; Exit the loop if Y = 0.           ; +2 = 101
	LDA <$00                                                          ; +3 = 104 (PAL: a 3-cycle instruction here makes this path 107 cycles)
	JMP TEST_BGSerialIn_Loop                                     ; +3 = 107
TEST_BGSerialIn_Exit:
	LDA $2002                ; Anyway, I could've just done that once instead of across the entire screen, but it was suggested to make it more visible.
	AND #$40                 ; Keep in mind, this value should show up as a white line, (color %10 of palette %11) instead of red, color %11 of palette %11.
	BEQ FAIL_BGSerialIn2     ; So we check if a sprite zero hit occurred, masked away everything but the sprite zero hit flag, and fail the test if no hit occured.
	;; END OF TEST ;;

	JSR WaitForVBlank        ; Wait for vblank...
	JSR SetUpDefaultPalette  ; Fix the color palette.
	LDA #1                   ; Return 1 to indicate a pass.
	RTS
;;;;;;;

DMASyncWithoutOpenBus:
	; REWRITTEN for the 2A07. Sync to the DMC DMA by executing an opcode from open bus.
	;
	; Hardware basis (NESdev forum "PAL DMA behavior", Fiskbit and lidnariq, Apr 2025: bus traces of an RP2A07):
	;  - the 2A07's DMA only halts the CPU on an opcode fetch; a DMA requested during any other cycle waits for the
	;    next opcode fetch. The halted fetch is repeated after the DMA.
	;  - the DMA steals 3 or 4 cycles (halt, dummy, optional alignment, the DMC read).
	;  - an open-bus read therefore never shows the DMA's byte (the 2A03 sync and its $4015 polling do not work), but an
	;    opcode FETCHED from open bus does: Fiskbit's suggestion in that thread.
	;
	; Method. A 1-byte looping sample at $FFC0 (the byte there is $00) plays at rate $F: one DMC read every 400 CPU
	; cycles (NESdev "APU DMC", PAL rate table: 50 * 8). Each pass of the loop below pushes a return address and the
	; flags and jumps to $4000. Nothing drives the bus there, so the opcode fetched is the last byte on the bus, the $40
	; of the JMP operand: RTI, which comes straight back (DMASyncOB_NotYet). If the DMA halts the CPU on that very
	; opcode fetch, the DMC read leaves $00 on the bus, the repeated fetch reads $00 = BRK, and the BRK goes through the
	; IRQ/BRK vector ($0600 in RAM, where a JMP DMASyncOB_Synced is installed for the duration).
	;
	; One pass is 398 CPU cycles. With the DMA's 3 or 4 stolen cycles a pass lasts 401 or 402 cycles, so against the
	; 400-cycle DMA grid the request moves 1 or 2 cycles EARLIER in the pass every pass. Coming down towards the $4000
	; fetch (call its cycle T0), the only opcode fetch above it is DMASyncOB_NotYet's first, 6 cycles later (the RTI).
	; A DMA held for an even number of cycles and one held for an odd number differ by one stolen cycle (the alignment
	; cycle), and the two cases are: "even = 4 stolen": request T0+2 -> held 4 -> 4 stolen -> moves 2 -> request T0,
	; lands on T0; request T0+1 -> held 5 -> 3 stolen -> moves 1 -> T0. "odd = 4 stolen": T0+1 -> held 5 -> 4 -> moves 2
	; -> T0-1, lands on T0 (held 1); T0+2 -> held 4 -> 3 -> moves 1 -> T0+1 -> T0-1. Either way the first pass that
	; detects, when the pass before it did not, has the DMA landing on T0 with 4 cycles stolen and the DMC read on
	; cycle T0+3; which of the two cases a 2A07 is cannot be told apart from here and does not need to be.
	; A detection with no clean pass before it (the request started inside the JMP) is thrown away and the loop goes on.
	;
	; CONTRACT AT THE RTS: the DMC read that synced was on cycle T0+3. This routine returns 78 cycles after T0, with the
	; sample set to play its last byte (loop off, IRQ off, rate $F, buffer full, 1 byte remaining), so:
	;   the next DMA lands on the first opcode fetch at or after T0+400, i.e. 322 cycles after the RTS ends
	;   (if an opcode fetch sits exactly 1 cycle before that point, the DMA may land there instead: avoid that).
	; From T0: 4 stolen + BRK 7 + JMP at $0600 3 = 14 to DMASyncOB_Synced, + 64 cycles there = 78.
	;
	; Uses A, the stack (X, Y and the three bytes at $0600 are saved on it), $0E/$0F (pass count). Leaves I set.
	TXA
	PHA
	TYA
	PHA
	SEI
	LDA $600
	PHA
	LDA $601
	PHA
	LDA $602
	PHA
	LDA #$4C                         ; JMP DMASyncOB_Synced at the IRQ/BRK target
	STA $600
	LDA #LOW(DMASyncOB_Synced)
	STA $601
	LDA #HIGH(DMASyncOB_Synced)
	STA $602
	LDA #$FF
	STA $4012                        ; sample address $FFC0 (a $00 byte)
	LDA #0
	STA $4013                        ; 1 byte
	STA $4015                        ; stop the DMC
	STA <$0E                         ; pass count
	STA <$0F
	LDA #$4F
	STA $4010                        ; loop, no IRQ, rate $F
	LDA #$10
	STA $4015                        ; start
	LDA #0
	STA $07EA                        ; 0 = synced (the abort path sets $FF)
	LDY #0                           ; Y = 1 once a pass has come back without a detection
DMASyncOB_Pass:                      ; 398 cycles from here back to here
	LDA #HIGH(DMASyncOB_NotYet)      ; 2
	PHA                              ; 3
	LDA #LOW(DMASyncOB_NotYet)       ; 2
	PHA                              ; 3
	PHP                              ; 3   the flags the RTI gives back
	JMP $4000                        ; 3   the opcode fetch at $4000 is cycle T0; RTI: 6
DMASyncOB_NotYet:                    ; 22
	LDY #1                           ; 2
	CLC                              ; 2
	LDA <$0E                         ; 3
	ADC #1                           ; 2
	STA <$0E                         ; 3
	LDA <$0F                         ; 3
	ADC #0                           ; 2
	STA <$0F                         ; 3
	CMP #4                           ; 2   1024 passes: more than two full trips around the 400-cycle grid
	BCS DMASyncOB_Abort              ; 2   -> 46
	LDX #69                          ; 2
DMASyncOB_Wait:
	DEX                              ; 2
	BNE DMASyncOB_Wait               ; 3   5 * 69 - 1 = 344 -> 392
	BIT <$00                         ; 3   -> 395
	JMP DMASyncOB_Pass               ; 3   -> 398
DMASyncOB_Synced:                    ; reached through BRK: T0 + 14
	TSX                              ; 2   drop the BRK's 3 bytes and the pass's 3
	TXA                              ; 2
	CLC                              ; 2
	ADC #6                           ; 2
	TAX                              ; 2
	TXS                              ; 2
	CPY #1                           ; 2
	BNE DMASyncOB_Reject             ; 2   -> 16
DMASyncOB_Restore:
	PLA                              ; 4
	STA $602                         ; 4
	PLA                              ; 4
	STA $601                         ; 4
	PLA                              ; 4
	STA $600                         ; 4   -> 40
	LDA #$0F                         ; 2
	STA $4010                        ; 4   loop off: the next DMC read is the sample's last -> 46
	PLA                              ; 4
	TAY                              ; 2
	PLA                              ; 4
	TAX                              ; 2   -> 58
	RTS                              ; 6   -> 64: T0 + 78. 322 cycles to T0 + 400.
DMASyncOB_Reject:                    ; detected with no clean pass before it: not usable, keep going
	LDY #0
	JMP DMASyncOB_Pass
DMASyncOB_Abort:                     ; never synced: put everything back and return (the caller's test will fail)
	LDA #$FF
	STA $07EA                        ; $07EA = $FF after a failed sync, 0 after a good one
	JMP DMASyncOB_Restore
	;;;;;;;
MarkTestToSkip:
	STX <Copy_X
	LDA <menuCursorYPos           ; A = which test from the current suite
	ASL A				          ; Double A, since we're reading a 2-byte word from a list of 2-byte words.
	TAX
	
	LDA <suitePointerList+1,X
	CMP #3	; if the page used to store the results is page 3 instead of page 4, it's a DRAW test. Forbid skipping it.
	BEQ MarkTestToSkip_RTS
	
	LDA <suitePointerList,X	      ; read the low byte of where to store the test results.
	STA <TestResultPointer        ; and store it in RAM
	LDA <suitePointerList+1,X     ; read the high byte of where to store the test results.
	STA <TestResultPointer+1      ; and store it in RAM next to the low byte.
	
	LDY #0                        ; set up Y for the upcoming indirect reads.
	LDA [TestResultPointer],Y     ; check if this test is already marked to be skipped.
	CMP #$FF                      ; If the "test results" are $FF, we need to clear it to zero.
	BEQ MarkTestToUnSkip
	LDA #$FF                      ; Mark this test to be skipped by storing $FF in the results.
	STA [TestResultPointer],Y
	BNE MarkTestToSkip_UpdateNametable	
MarkTestToUnSkip:
	LDA #0                        ; Mark this test as not-yet-ran.
	STA [TestResultPointer],Y
MarkTestToSkip_UpdateNametable:
	LDX <menuCursorYPos
	JSR DrawTEST
	JSR UpdateTESTAttributes
	LDA <AutomateTestSuite        ; I use AutomateTestSuite when pressing B to mark all tests on a suite to be skipped.
	BNE MarkTestToSkip_RTS
	JSR HighlightTest
MarkTestToSkip_RTS:
	LDX <Copy_X
	RTS
;;;;;;;

SkipSuiteName:
	LDA [AllTestMenuTestNameOffsetLo],Y ; Read from the pointer
	INY
	CMP #$FF
	BNE SkipSuiteName
	TYA
	CLC
	ADC <AllTestMenuTestNameOffsetLo
	STA <AllTestMenuTestNameOffsetLo
	BCC SkipSuiteName0
	INC <AllTestMenuTestNameOffsetHi ; If needed, INC the high byte
SkipSuiteName0:
	RTS
;;;;;;;

AddYToNameOffset: ; This function adds the A register to the word at $0000
	TYA
	CLC
	ADC #4
	BCC AddYToNameOffset0
	INC <AllTestMenuTestNameOffsetHi ; If needed, INC the high byte
AddYToNameOffset0:
	CLC
	ADC <AllTestMenuTestNameOffsetLo
	STA <AllTestMenuTestNameOffsetLo
	BCC AddYToNameOffset1
	INC <AllTestMenuTestNameOffsetHi ; If needed, INC the high byte
AddYToNameOffset1:
	RTS
;;;;;;;

SetUpSpriteZero:
	JSR CopyReturnAddressToByte0
	LDY #0
SetUpSpriteZero_Loop:
	LDA [$0000], Y
	STA $200, Y
	INY
	CPY #$4
	BNE SetUpSpriteZero_Loop
	JSR FixRTS
	RTS
;;;;;;;

SetPPUSCROLLFromWord:	; pretty much the same as SetPPUADDRFromWord, but it writes to $2005.
	STA <$FF
	STY <$FE
	JSR CopyReturnAddressToByte0
	LDA $2002
	LDY #0
	LDA [$0000],Y
	STA $2005
	INY
	LDA [$0000],Y
	STA $2005
	INY
	JSR FixRTS
	LDY <$FE
	LDA <$FF
	RTS
;;;;;;;

LSM_CopySuitePointerToByte0: ; I moved this subroutine over here to make space. It's relatively far from where it gets used, but now there's zero bytes of padding here between this routine and the .org
	LDA <suitePointer
	STA <$00
	LDA <suitePointer+1
	STA <$01
	RTS
;;;;;;


	; [Suddenly Resize Sprite] is placed here, in free space before $EEC0.
FAIL_SuddenlyResizeSprite:
	JMP TEST_Fail
TEST_SuddenlyResizeSprite:

	;;; Test 1 [Suddenly Resize Sprite]: Verify Sprite Zero Hits behave properly. ;;;
	JSR VerifySpriteZeroHits
	BNE P3sizeSprite_1
FAIL_SuddenlyResizeSprite_N20:
	JMP FAIL_SuddenlyResizeSprite
P3sizeSprite_1:
	INC <ErrorCode

	;;; Test 2 [Suddenly Resize Sprite]: What happens if you write to $2001 during HBlank at *just* the right time to resize an 8px tall sprite to a 16px tall sprite? ;;;
	JSR PrintCHR               ; Clear the nametable byte set up by the previous error code.
	.word $2C21                ; ^
	.byte $24, $FF             ; ^
	
	JSR PrintCHR               ; Set up nametable
	.word $2C10                ; ^
	.byte $C6, $FF             ; ^
	
	JSR SetPPUADDRFromWord     ; Update t
	.byte $2C, $00             ; This is also needed for the sprite zero hit.
	
	; This test will need to set up sprite zero on the following scanline (prepare sprite zero information in OAM2) and disable rendering.
	; Then, after 8 to 15 scanlines, re-enable rendering just before H-Blank, and 
	JSR SetUpSpriteZero        ; Prepare sprite zero with the following values:
	.byte $00, $CE, $03, $80   ; $CE is empty, but $CF is a single pixel on scanline 4. This will become a 16px tall sprite.
	JSR Sync_ToLine0Dot1
	JSR Clockslide_50
	JSR Clockslide_43 ; PAL: the write below lands on dot 321 of scanline 0 (the 2C02 version: dot 320)
	LDA #0
	NOP
	STA $2001          ; Disable rendering!
	
	; At this moment, we're ready for a sprite zero hit on the next rendered scanline.
	; Additionally, OAM2 contains $00, $E2, $03, and $80.
	
	; re-enable rendering at the start of H-Blank, scanline 14.
	; Since we're at the end of HBlank scanline 0, we have 14 full scanlines - 1 HBlank to go.
	; About 4700 PPU dots until scanline 14's sprite evaluation is done: 1470 CPU cycles at 3.2 dots per cycle.
	
	JSR ClockslideFromWord
	.word 1460 ; PAL: 3.2 dots per CPU cycle; the enable write lands on dot 245 of scanline 14 (2C02 version: 244)
	
	LDA #$18
	LDX #$23
	STA $2001
	STX $2000
	
	; In theory, a sprite zero hit will occur next scanline now.
	
	JSR WaitForVBLSpriteZeroHit; Wait for vblank and load A with $2002.6
	BEQ FAIL_SuddenlyResizeSprite_N20
	INC <ErrorCode
	
	;;; Test 3 [Suddenly Resize Sprite]: What if we do the same thing as the previous test, but enable the 16px sprite mode AFTER sprite zero is added to the shift registers? ;;;

	JSR Sync_ToLine0Dot1
	JSR Clockslide_50
	JSR Clockslide_43 ; PAL: the write below lands on dot 321 of scanline 0 (the 2C02 version: dot 320)
	LDA #0
	NOP
	STA $2001          ; Disable rendering!
	
	; At this moment, we're ready for a sprite zero hit on the next rendered scanline.
	; Additionally, OAM2 contains $00, $E2, $03, and $80.
	
	; re-enable rendering at the start of H-Blank, scanline 14.
	; Since we're at the end of HBlank scanline 0, we have 14 full scanlines - 1 HBlank to go.
	; About 4700 PPU dots until scanline 14's sprite evaluation is done: 1470 CPU cycles at 3.2 dots per cycle.
	
	JSR ClockslideFromWord
	.word 1466 ; PAL (see test 2)
	LDA #$18
	LDX #$23
	STA $2001
	STX $2000
	
	; In theory, a sprite zero hit will NOT occur next scanline now.
	
	JSR WaitForVBLSpriteZeroHit; Wait for vblank and load A with $2002.6
	BEQ P3sizeSprite_3
FAIL2_SuddenlyResizeSprite_N22:
	JMP FAIL2_SuddenlyResizeSprite
P3sizeSprite_3:
	INC <ErrorCode
	
	;;; Test 4 [Suddenly Resize Sprite]: What about going from a 16px tall sprite that was detected on this scanline, and setting PPUCTRL to use 8px tall sprites? ;;;
	
	JSR PrintCHR               ; Clear the nametable byte set up by the previous error code.
	.word $2C10                ; ^
	.byte $24, $FF             ; ^
	
	JSR PrintCHR               ; Set up nametable
	.word $2C50                ; ^
	.byte $C0, $FF             ; ^
	
	JSR SetPPUADDRFromWord     ; Update t
	.byte $2C, $00             ; This is also needed for the sprite zero hit
	LDA #0
	STA $2005
	STA $2005
	
	JSR Sync_ToLine0Dot1
	JSR ClockslideFromWord
	.word 1671 ; PAL: the $2000 write lands on dot 253 of scanline 15 (2C02 version: 254)
	LDA #3
	STA $2000

	; In theory, a sprite zero hit will NOT occur next scanline.
	
	JSR WaitForVBLSpriteZeroHit; Wait for vblank and load A with $2002.6
	BNE FAIL2_SuddenlyResizeSprite_N22
	INC <ErrorCode

	;;; Test 5 [Suddenly Resize Sprite]: What if we do the same thing as the previous test, but disable the 16px sprite mode AFTER sprite zero is added to the shift registers? ;;;
	LDA #$23
	STA $2000
	JSR Sync_ToLine0Dot1
	JSR ClockslideFromWord
	.word 1679           ; PAL: the $2000 write lands on dot 275 of scanline 15 (2C02 version: 274)
	LDA #3
	STA $2000

	; In theory, a sprite zero hit will occur next scanline.
	
	JSR WaitForVBLSpriteZeroHit; Wait for vblank and load A with $2002.6
	BEQ FAIL2_SuddenlyResizeSprite_N22
	
	;; END OF TEST ;;

	LDA #1
	RTS
;;;;;;;
MisalignedOAM2_OAM:
	.byte $00, $01, $02, $03
	.byte $01, $21, $22, $23
	.byte $02, $41, $42, $43
	.byte $03, $61, $62, $63
	.byte $04, $81, $82, $83
	.byte $05, $A1, $A2, $A3
	.byte $06, $C1, $C2, $C3
	.byte $07, $E1, $E2, $E3
	
	; [Misaligned OAM2 Address] is placed here, in free space before $EEC0.
MisalignedOAM2RevE:
	JMP Stress2004_RevE
OAMDATA_Check:
	LDA #$5A
	STA $2004 ; OAMADDR will be zero.
	TXA
	LDX #1
	STA $2002
	STA $2002, X ; safely write to $2003 without the risk of OAM corruption... a bit ironic considering the test we're running.
	LDA #$A5
	STA $2002
	LDA $2004
	CMP #$A5
	RTS
;;;;;;;

TEST_MisalignedOAM2Addr:
	;;; Test 1 [Misaligned OAM2 Address]: Verify sprite zero hits before running the actual test. ;;;
	JSR VerifySpriteZeroHits ; Use this subroutine to verify if sprite zero hits are working.
	BNE MO2_Skip1
FAIL_MisalignedOAM2Addr_N25:
	JMP FAIL_MisalignedOAM2Addr
MO2_Skip1:
	INC <ErrorCode
	
	;;; Test 2 [Misaligned OAM2 Address]: Verify OAMDATA is readable ;;;

	JSR OAMDATA_Check
	BNE MO2_Skip2
MisalignedOAM2RevE_N26:
	JMP MisalignedOAM2RevE
MO2_Skip2:
	INC <ErrorCode

	;;; Test 3 [Misaligned OAM2 Address]: Reading from $2004 during dots 321 through 340 (under normal behavior) will read from index 0 of OAM2 ;;;

	JSR ClearPage2 ; Overwrite page 2 with all FFs
	LDA #$5A       ; Write $5A to the final Y position in primary OAM.
	STA $2FC

	JSR Sync_ToLine0Dot1
	JSR Clockslide_50
	JSR Clockslide_44 ; PAL: the $2004 read below lands on dot 324 of scanline 0 (2C02 version: 322)
	NOP
	NOP
	LDA $2004 ; Read on dot 324. (The opcode is read on dot 313)
	
	CMP #$5A ; Check if it was index 0 of OAM2.
	BNE FAIL_MisalignedOAM2Addr_N25
	INC <ErrorCode

	;;; Test 4 [Misaligned OAM2 Address]: Verify accurate OAM2Address behavior ;;;
	; Ideally I would test this by triggering a sprite zero hit, formed by enabling rendering on dot 256 or 257, with the OAM2 Address non-zero at the time...
	; But alas, that has clock alignment specific instability.
	; So instead, I'll fill OAM2, disable rendering between dots 320 and 340, re-enable rendering during the following sprite fetch, and then read from $2004 between dots 320 and 340.
	; Typically, that range reads from index 0 of OAM2, but since we misaligned the OAM2 Address, this time it will not.
	
	; OAM2 should be [00, 01, 02, 03, 01, 21, 22, 23, 02, 41, 42, 43, 03, 61, 62, 63, 04, 81, 82, 83, 05, A1, A2, A3, 06, C1, C2, C3, 07, E1, E2, E3]
	; We disable rendering on dot 268, when the OAM2 Address was $07. (pointing to the value of $23)
	; Then we enable rendering on dot 286, where the OAM2 address is still $07.
	; By the time we finish sprite fetch, due to the 18 missing dots, the OAM2 Address has only incremented to $18, where we can ten read the value of $06 from $2004.
	
	; NOTE: There are certainly ways you can be emulating the OAM2 Address incorrectly, yet still pass this test.
	; As mentioned above, the ideal method for testing this (with a sprite zero hit) is unstable on certain cpu/ppu clock alignments.
	; Hence the significantly more lenient test I present below.
	; Since I'm unable to create a more strict version of this test, it is up to you to recognize if your emulator is actually implementing this correctly.
	
	
	LDX #$1F
TEST_MisalignedOAM2_Loop:
	LDA MisalignedOAM2_OAM, X
	STA $200, X
	DEX
	BPL TEST_MisalignedOAM2_Loop

	JSR Sync_ToLine0Dot1
	
	JSR ClockslideFromWord
	.word 34068
	; PAL: rendering has to be off for 18 dots, as in the 2C02 version (dots 268-286). The writes below are 6 CPU
	; cycles (19.2 dots) apart, so the exact dots decide how many sprite-fetch dots are lost. This wait is one PAL frame
	; (33248 cycles, half a cycle more than a frame: 1.6 dots of phase) plus 820, which puts the writes on
	; dots 267 and 286.2 of scanline 7 and the read on dot 337.4. The CPU/PPU phase of a real console is not validated.
	
	LDA #0
	LDX #$1E
	STA $2001 ; disable on dot 268
	NOP
	STX $2001 ; enable on dot 286
	JSR Clockslide_12
	LDA $2004

	CMP #$06
	STA <$50
	BNE FAIL_MisalignedOAM2Addr_N25

	LDA #1
	RTS
;;;;;;;
KEYDATA_4:
	.byte $12, $80, $BC, $80, $C0, $80, $C4, $80, $C8, $80, $CC, $80, $D0, $80, $D4, $80
	.byte $D8, $80, $DC
	.byte $82, $2F
	.byte $83, $3A
	.byte $05, $7E, $80, $7D, $80, $7C
	.byte $84, $BF
	.byte $85, $C8
	.byte $82, $BF
	.byte $82, $BD
	.byte $84, $01
	.byte $82, $BF
	.byte $82, $BD
	.byte $84, $01
	.byte $82, $BF
	.byte $82, $BD
	.byte $84, $01
	.byte $82, $BF
	.byte $82, $BD
	.byte $84, $01
	.byte $82, $BF
	.byte $82, $BD
	.byte $84, $01
	.byte $82, $BF
	.byte $82, $BD
	.byte $84, $01
	.byte $82, $BF
	.byte $82, $BD
	.byte $80, LOW(KEYDATA_5), HIGH(KEYDATA_5) ; continued
	.org $EEC0	
DPCM_Sample_60:
	.byte $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60
	.byte $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60, $60
	.byte $60

	; [Stale Sprite Shift Regs] is placed here, in free space before $EFC0.
TEST_StaleSpriteShiftRegs:
	
	;;; Test 1 [Stale Sprite Shift Registers]: Verify sprite zero hits are working. ;;;

	JSR VerifySpriteZeroHits      ; We already have a subroutine to verify sprite zero hits are working properly.
	BNE P3eShiftRegs_1
TEST_Fail_N29:
	JMP TEST_Fail
P3eShiftRegs_1:
	INC <ErrorCode

	;;; Test 2 [Stale Sprite Shift Registers]: Disabling rendering does not stop the sprite counters. ;;;
	; Basically, if a sprite should be drawn at a specific X coordinate, disabling rendering before that dot won't affect it.

	JSR SetUpSpriteZero           ; Prepare sprite zero with the following values:
	.byte $05, $C5, $03, $FE      ; 1x8 pixel stripe, but it's placed at X=$FE.	
	JSR OAMDMAWithPage2           ; OAM DMA with page 2.
	
	JSR WriteToPPUADDRWithByte    ; Put a box at $2C1F for the attempted sprite zero hit (that will fail)
	.byte $2C, $1F                ; Address $2C1F (upper right corner of the screen.)
	.byte $FE, $FF                ; CHR $FE, (solid 8x8 box) followed by the terminator byte.
	
	JSR WriteToPPUADDRWithByte    ; While we're here, we might as well put a box at $2C00 for the next part of the test.
	.byte $2C, $00                ; Address $2C00 (upper left corner of the screen.)
	.byte $FE, $FF                ; CHR $FE, (solid 8x8 box) followed by the terminator byte.
	
	JSR ResetScroll_2C00          ; Reset the scroll to nametable address $2C00.
	
	JSR Sync_ToLine0Dot1          ; sync the CPU to dot 1 of scanline 0.
	JSR ClockslideFromWord
	.word 531                     ; PAL: the disable write lands on dot 15 of scanline 5, as in the 2C02 version.
	LDA #0                        ;
	STA $2001                     ; Disable rendering around dot 15-ish
	LDA #$1E                      ;
	STA $2001                     ; Enable rendering around dot 33-ish
	                              ; Rendering was disabled for 18 ppu cycles, but the sprite counters were NOT halted during that time.
	                              ; If they were halted, then the sprite wouldn't be drawn at all, as HBlank would begin before the counters reach zero.
	                              ; But since they weren't halted, the sprite will still be drawn at X=FE, therefore the sprite zero hit still works.
	JSR WaitForVBLSpriteZeroHit   ; Wait for vblank and load A with $2002.6
	BNE P3eShiftRegs_2
FAIL_StaleSpriteShiftRegs_N30:
	JMP FAIL_StaleSpriteShiftRegs
P3eShiftRegs_2:
	INC <ErrorCode

	;;; Test 3 [Stale Sprite Shift Registers]: Disabling rendering does stop the sprite shifters. ;;;
	; However, the actual process of using the shift register and drawing the sprite does get paused during Forced Blanking.

	JSR SetUpSpriteZero           ; Prepare sprite zero with the following values:
	.byte $04, $C5, $03, $30      ; 1x8 pixel stripe, but it's placed at X=$30.	
	JSR OAMDMAWithPage2           ; OAM DMA with page 2.

	JSR Sync_ToLine0Dot1          ; sync the CPU to dot 1 of scanline 0.
	JSR ClockslideFromWord
	.word 525                     ; PAL: the disable write lands on dot 336 of scanline 4, as in the 2C02 version.
	LDA #0                        ;
	STA $2001                     ; Disable rendering around dot 0-ish, while the background shifters are full.
	JSR ClockslideFromWord
	.word 1059                    ; PAL: 3.2 dots per CPU cycle; the enable write lands on dot 334 of scanline 14.
	LDA #$1E                      ;
	STA $2001                     ; Enable rendering around scanline 14 dot 340
	JSR WaitForVBLSpriteZeroHit   ; Wait for vblank and load A with $2002.6
	BEQ FAIL_StaleSpriteShiftRegs_N30
	INC <ErrorCode

	;;; Test 4 [Stale Sprite Shift Registers]: Additional check that a sprite at X=$FF doesn't trigger a sprite zero hit. ;;;
	
	JSR SetUpSpriteZero           ; Prepare sprite zero with the following values:
	.byte $03, $C5, $03, $FF      ; 1x8 pixel stripe, but it's placed at X=$FF.	
	JSR OAMDMAWithPage2           ; OAM DMA with page 2.
	
	JSR WaitForVBLSpriteZeroHit   ; Wait for vblank and load A with $2002.6
	BNE FAIL_StaleSpriteShiftRegs_N30
	INC <ErrorCode

	;;; Test 5 [Stale Sprite Shift Registers]: What if we prepare the sprite counter but don't let the counter activate on dot 339? ;;;

	; More info about how the sprite shifters work in case you need it:
	; The sprites are only drawn after their "shifter counter" reaches zero. (each sprite being drawn has their own shifter counter)
	; This shifter counter is initialized during sprite fetch when the X position of a sprite is determined. (using the value of the X position.)
	; The shifter counter has two modes: "halted" and "counting".
	; - When halted, the sprite is being drawn, and the sprite shifter is shifting.
	; - when counting, the counter is simply decremented until it reaches zero. Once it reaches zero, it switches to "halted" mode.
	; - If the ppu is rendering on dot 339, then the shifter counters are set to "counting". 
	;   - If rendering was not enabled on dot 339, the shifter counters will be in whatever state they were previously in, which is likely "halted".
	; The plan for this test is to let the counter reload with $FF, but leave the state as "halted" which will draw the sprite immediately as soon as rendering is enabled.
	
	; Rendering will be disabled before dot 339, and it will remaining that way through dot 339 (and quite a good bit into the following scanline).
	; In other words, Dot 339 will be during F-Blank.
	; This prevents the counters from changing their state from "halted" to "counting". 
	; Since they will be in the "halted" state as soon as rendering is enabled, the sprite will be draws as soon as rendering is enabled, triggering the sprite zero hit.

	JSR Sync_ToLine0Dot1          ; sync the CPU to dot 1 of scanline 0.
	JSR ClockslideFromWord
	.word 418                     ; PAL: the disable write lands on dot 335 of scanline 3 (2C02 version: 334).
	LDA #0                        ; A value of 0 to disable rendering.
	STA $2001                     ; this instruction begins on scanline 3, dot 325. Accounting for the delay, rendering should be disabled around dot 334 or 335.
	JSR Clockslide_46             ; stall a while so HBlank can end (PAL: the enable lands on dot 160 of scanline 4, 2C02 version 161).
	LDA #$1E                      ; A value of $1E to enable both sprites and the background, including the 8 pixels on the left edge of the screen.
	STA $2001                     ; this instruction begins on scanline 4, dot 152. Accounting for the delay, rendering should be enabled around dot 161 or 162.
	
	JSR WaitForVBLSpriteZeroHit   ; Wait for vblank and load A with $2002.6
	BEQ FAIL_StaleSpriteShiftRegs_N30
	
	INC <ErrorCode


	;;; Test 6 [Stale Sprite Shift Registers]: Can a sprite at X=$FF trigger a sprite zero hit by preventing the shifter from reloading during HBlank? ;;;
	; Disabling rendering on dot 257 (or 258 depending on clock alignment) will prevent the sprite shifters from being reloaded.
	; Sprite zero's shifter was never fully shifted, and will stop shifting during HBlank.
	; So if we re-enable rendering during the ppu idle period, we can shift the rest of sprite zero's shifter on the following scanline to trigger the sprite zero hit.

	; When we run this test, the sprite counter will be set up with $FF.
	; Then every visible ppu cycle, this counter is decremented until 0 where the sprite is drawn and the sprite shifter will begin shifting.
	; This results in a single pixel drawn at X=$FF for sprite zero.
	; Since the sprite shifters do not shift while rendering is disabled (or blanked) they stop shifting during HBlank.
	; Then we disable rendering until the ppu idle period, skipping the re-initialization of the counter.
	; Since the counter is still zero, and the shift register still has contents, the sprite will be drawn immediately as soon as rendering is re-enabled.
	; Rendering will be enabled before dot 339, but since sprite zero's shifter counter is already at zero, it will just be set to halted mode again, and immediately draw the sprite on the first pixel.

	JSR Sync_ToLine0Dot1          ; sync the CPU to dot 1 of scanline 0.
	JSR ClockslideFromWord
	.word 500                     ; PAL: the disable write lands on dot 256 of scanline 4 (2C02 version: 257).
	LDA #0                        ; A value of 0 to disable rendering.
	STA $2001                     ; this instruction begins on scanline 4, dot 248. Accounting for the delay, rendering should be disabled around dot 258 or 259.
	LDA #$1E                      ; A value of $1E to enable both sprites and the background, including the 8 pixels on the left edge of the screen.
	JSR Clockslide_19             ; wait for the end of HBlank (PAL: the enable lands on dot 336 of scanline 4, 2C02 version 335).
	STA $2001                     ; this instruction begins on scanline 4, dot 326. Accounting for the delay, rendering should be enabled around dot 336 or 337.
	JSR WaitForVBLSpriteZeroHit   ; Wait for vblank and load A with $2002.6
	BEQ FAIL_StaleSpriteShiftRegs_N30

	;; END OF TEST ;;	

	LDA #1
	RTS
;;;;;;;
	.org $EFC0
TEST_DMC_ConflictsSample:
	.byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
	.byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
	.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF
	.byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF
	; yes, the sample does technically include the first byte at $F000, but the test that uses this sample doesn't care.
	.org $F000

	; It is important that this function doesn't move around and cause branches to start crossing page boundaries.
; PAL pre-render sync: 312-line, no-short-frame timing.
Sync_ToPreRenderDot324:
	; PAL has no short frame, so there is no even/odd frame branch here.
	SEI
	LDA #$00
	STA $4017 ; enable the frame counter IRQ.
	; Every caller of this routine expects it to perform the page-2 OAM DMA. It is done BEFORE the sync: a DMA takes
	; 513 or 514 CPU cycles depending on the APU's get/put parity at that moment, which the sync does not fix, so a DMA
	; after the sync made this routine's return move by one CPU cycle from call to call (and on a console, from
	; power-on to power-on). Start the DMA at OAM[0]; otherwise a previous test's OAMADDR shifts it.
	; First let an OAM corruption left pending by the caller happen (FlushPendingOAMCorruption): with rendering off until
	; after the sync, it would otherwise land on the new OAM when this routine turns rendering on.
	JSR FlushPendingOAMCorruption
	LDA #0
	STA $2003
	JSR OAMDMAWithPage2
	JSR WaitForVBlank
	JSR New_VBL_Sync ; sync to scanline 241, dot 0
	; 70 scanlines (241 -> pre-render 311) plus dot 324: the 6976 cycles that followed the DMA before, plus the 538 the
	; DMA's code took when it was here (LDA/STA $2003, JSR, DMA with the alignment cycle, RTS).
	; This routine is named for pre-render dot 324; callers rely on that.
	JSR ClockslideFromWord
	.word 7514
	JSR EnableRendering
	RTS
;;;;;;;

Sync_ToLine0Dot1:
	JSR Sync_ToPreRenderDot324
	RTS
;;;;;;;

EnableRendering:; Enables rending both sprites and background. Does not affect the other mask flags.
	PHA
	LDA <PPUMASK_COPY
	ORA #$18
	STA <PPUMASK_COPY
	STA $2001
	PLA
	RTS
;;;;;;;

EnableRendering_BG:; Enables rending the background. Does not affect the other mask flags.
	PHA
	LDA <PPUMASK_COPY
	ORA #$08
	STA <PPUMASK_COPY
	STA $2001
	PLA
	RTS
;;;;;;;

EnableRendering_S:; Enables rending sprites. Does not affect the other mask flags.
	PHA
	LDA <PPUMASK_COPY
	ORA #$10
	STA <PPUMASK_COPY
	STA $2001
	PLA
	RTS
;;;;;;;

EnableFullRendering:; Enables rending both sprites and background, and the 8 pixel mask. Does not affect the other mask flags.
	PHA
	LDA <PPUMASK_COPY
	ORA #$0E
	STA <PPUMASK_COPY
	STA $2001
	PLA
	RTS
;;;;;;;

DisableRendering:; Disables rending both sprites and background. Does not affect the other mask flags.
	PHA
	LDA <PPUMASK_COPY
	AND #$E7
	STA <PPUMASK_COPY
	STA $2001
	PLA
	RTS
;;;;;;;

DisableRendering_BG:; Disables rending the background. Does not affect the other mask flags.
	PHA
	LDA <PPUMASK_COPY
	AND #$F7
	STA <PPUMASK_COPY
	STA $2001
	PLA
	RTS
;;;;;;;

DisableRendering_S:; Disables rending sprites. Does not affect the other mask flags.
	PHA
	LDA <PPUMASK_COPY
	AND #$EF
	STA <PPUMASK_COPY
	STA $2001
	PLA
	RTS
;;;;;;;

EnableNMI:; Enables the NMI. Does not affect the other PPUCRTL flags.
	PHA
	LDA <PPUCTRL_COPY
	ORA #$80
	STA <PPUCTRL_COPY
	STA $2000
	PLA
	RTS
;;;;;;;

DisableNMI:; Disables the NMI. Does not affect the other PPUCRTL flags.
	PHA
	LDA <PPUCTRL_COPY
	AND #$7F
	STA <PPUCTRL_COPY
	STA $2000
	PLA
	RTS
;;;;;;;

ResetScroll_2C00:; sets the PPU "v" register to $2C00
	LDA #$2C
	.byte $CD ; CMP Absolute to skip the next two byte. This .byte $CD is effectively a 1-byte long "branch two bytes"
ResetScroll:; sets the PPU "v" register to $2000
	LDA #$20
	CMP $2002
	STA $2006	; Update high byte of v to $20
	LDA #$00
	STA $2006   ; Update low byte of v to $00
	STA $2005	; Update fine X scroll with $00
	STA $2005	; Update fine Y scroll with $00
	RTS
;;;;;;;

ClearNametable:; Overwrites the nametable from $2000 to $2FFF with $24. Attribute tables in this area are cleared to $00
	PHA
	JSR SetPPUADDRFromWord
	.byte $20, $00
	LDA #$24
	LDX #$10 ; Okay, so I'm honestly being pretty lazy here (let's just say I was optimizing for fewer bytes rather than cpu cycles)
	LDY #$00
NTLoop1:
	STA $2007
	DEY
	BNE NTLoop1
	DEX
	BNE NTLoop1
	; Now set up the attributes properly
	JSR SetPPUADDRFromWord
	.byte $23, $C0
	LDA #$00
	LDX #$40
NTLoop2:
	STA $2007
	DEX
	BNE NTLoop2
	; And the other attributes
	JSR SetPPUADDRFromWord
	.byte $2F, $C0
	LDA #$00
	LDX #$40
NTLoop3:
	STA $2007
	DEX
	BNE NTLoop3
	PLA
	RTS
;;;;;;;

ClearRAMExceptPage3: ; Clears RAM from $0000 to $07FF, except leaving $0300 through $3FF untouched.
	; page 3 is where I'm keeping the uninitialized RAM values, so don't clear that.
	; also don't clear the stack, ha.
	LDA #0
	LDX #0
ClearRamLoop:
	STA <$00,X
	; (Page 2 is not cleared here: it is overwritten with $FF right after ClearRAMExceptPage3 runs.)
	STA $400,X
	INX
	BNE ClearRamLoop
	; flow into the code that clears the rest on RAM.
ClearPage5: ; Page 5 is reserved for RAM used by tests. It's a good idea to clear this before any tests.
	LDA #0
	LDX #0
ClearPage5Loop:
	STA $500,X
	STA $600,X ; it also clears page 6. (The IRQ Vector points to $600, but there are no IRQs by default. Any test needing this space should initialize it during the test)
	STA $700,X ; it also clears page 7. (The NMI vector points to $700, but the NMI routine is set up again at the end of any tests, so don't worry)
	INX
	BNE ClearPage5Loop
	; let's also clear $50 - $6F on the zero page. also $20 to $2F
ClearPage5ZPLoop:
	STA <$20,X
	STA <$50,X
	STA <$60,X
	INX
	CPX #$10
	BNE ClearPage5ZPLoop
	RTS
;;;;;;;

ClearPage2: ; Page 2 is reserved for OAM. Let's clear it with FFs.
	STX <Copy_X	; Keep a copy of X
	LDA #$FF
	LDX #0
ClearPage2Loop: ; There is no need to unroll/optimize this loop. The bytes saved is worth more than the cpu cycles saved.
	STA $200,X
	INX
	BNE ClearPage2Loop
	LDX <Copy_X ; restore X
	RTS
;;;;;;;

PrintText:
	; Following a JSR here should be .word $HiLo (the target PPU Address)
	; And following that .word should be a string "Hello World!" and a terminator, $FF
	; This function updates the return address, skipping the word and bytes.
	; Print the string (bytes) at the target PPU Address (word).
	STA <Copy_A	; Keep a copy of the A, X, and Y registers
	STY <Copy_Y	; ^
	STX <Copy_X	; ^
	LDA <dontSetPointer
	BNE PT_dontSetPointer
	JSR CopyReturnAddressToByte0
	LDY #1
	LDA $2002
	LDA [$0000],Y ; Read from the pointer
	STA <$03
	DEY
	LDA [$0000],Y
	STA <$04
	LDA #02
	JSR AddAToByte0
PT_dontSetPointer:
	LDA <$03
	STA $2006
	LDA <$04
	STA $2006
PTloop:
	LDA [$0000],Y
	BPL PTloop_Cont
	CMP #$FF
	BEQ PTpostLoop
	JSR PrintTextSpecialString
	JMP PTloop
	
PTloop_Cont:
	TAX
	LDA AsciiToCHR-32, X ; convert from ascii to my 0123456789ABCDEFGHI... format
	LDX <HighlightTextPrinted
	BEQ PT_SkipHighlight
	ORA #$80
PT_SkipHighlight:
	STA $2007
	INY
	BNE PTloop ; Branch always to the loop
PTpostLoop:	
	INY
	LDA <dontSetPointer
	BNE PTskipFixRTS
	JSR FixRTS
	LDY <Copy_Y	; Restore Y
PTskipFixRTS:
	LDX <Copy_X ; Restore X
	LDA <Copy_A ; Restore A
	RTS
;;;;;;;


PrintTextSpecialString:
	; If the character we're reading is from a special list, we need to substitute it.
	; This was a byte-saving measure so I didn't have the string "absolute" or "zeropage" in the ROM dozens of times.
	AND #$7
	TAX
	STY <$40
	LDY PrintTextSpecLengths, X
	STY <$41 ; It's okay to use this, since it will be set to 0 by the time this routine is through.
	LDY PrintTextSpecOffsets, X
PT_SpecialCharLoop:
	LDA PrintTextSpecialStrings, Y
	TAX
	LDA AsciiToCHR-32, X ; convert from ascii to my 0123456789ABCDEFGHI... format
	LDX <HighlightTextPrinted
	BEQ PT_SkipHighlight1
	ORA #$80
PT_SkipHighlight1:
	STA $2007
	INY
	DEC <$41
	BNE PT_SpecialCharLoop
	LDY <$40
	INY
	RTS
;;;;;;;

PrintTextSpecialStrings:
	.byte " indirect"
	.byte " zeropage"
	.byte " absolute"
	.byte " immediate"
	.byte "Unofficial Instructions: "

PrintTextSpecOffsets:
	.byte 0, 9, 18, 27, 37
PrintTextSpecLengths:
	.byte 9, 9, 9, 10, 25

PrintTextCentered:
	; Following a JSR here should be .word $HiLo (the target PPU Address)
	; And following that .word should be a string "Hello World!" and a terminator, $FF
	; This function updates the return address, skipping the word and bytes.
	; Print the string (bytes) at the target PPU Address (word), except center the text to the middle of the screen.
	STA <Copy_A
	STY <Copy_Y
	STX <Copy_X
	LDA <dontSetPointer
	BNE PTC_dontSetPointer
	JSR CopyReturnAddressToByte0
	LDY #1
	LDA $2002
	LDA [$0000],Y ; Read from the pointer
	STA <$03
	DEY
	LDA [$0000],Y
	STA <$04
	LDA #02
	JSR AddAToByte0
	; Get length of the string.
PTC_dontSetPointer:
	LDY #$FF
	LDA #$0
	STA <$40
PTCGetLength:
	INY
	LDA [$0000],Y
	BPL PTCGetLength
	CMP #$FF
	BEQ PTCGetLength_Exit
	STY <$42
	AND #$7
	TAX
	LDY PrintTextSpecLengths, X
	TYA
	STA <$40
	LDY <$42
	JMP PTCGetLength
	
		
PTCGetLength_Exit:
	LDA <$04 ; take pointer low byte
	AND #$E0  ; remove low 5 bits
	ORA #$10  ; add bit 5
	STA <$04
	TYA
	CLC
	ADC <$40 ; If we encountered a special string, we need to add 9 to the length.
	LSR A ; divide length by 2
	EOR #$FF ; make negative
	CLC
	ADC #01
	CLC
	ADC <$04 ; Add the low byte
	STA <$04
	LDA <$03
	STA $2006
	LDA <$04
	STA $2006	
	LDY #0
PTCloop:
	LDA [$0000],Y
	BPL PTCloop_Cont
	CMP #$FF
	BEQ PTCpostLoop
	JSR PrintTextSpecialString
	JMP PTCloop
	
PTCloop_Cont:
	TAX
	LDA AsciiToCHR-32, X ; convert from ASCII to my 0123456789ABCDEFGHI... format
	LDX <HighlightTextPrinted
	BEQ PTC_SkipHighlight
	ORA #$80
PTC_SkipHighlight:
	STA $2007
	INY
	BNE PTCloop ; Branch always to the loop
PTCpostLoop:	
	INY
	LDA <dontSetPointer
	BNE PTCskipFixRTS
	JSR FixRTS
	LDY <Copy_Y
PTCskipFixRTS:
	LDX <Copy_X
	LDA <Copy_A
	RTS
;;;;;;;

Print32Bytes:
	; Following a JSR here should be .word $HiLo (the target PPU Address)
	; And following that word should be a second .word, acting as the "target address"
	; print the 32 bytes found at the target address at the target PPU address.
	JSR CopyReturnAddressToByte0
	LDA $2002
	LDY #$01
	LDA [$0000],Y ; update PPUADDR
	STA $2006
	STA <$02
	DEY
	LDA [$0000],Y
	STA $2006
	STA <$03
	LDA #02
	JSR AddAToByte0	
	LDA [$0000],Y ; copy new pointer to $04 and $05
	STA <$04
	INY
	LDA [$0000],Y ; copy new pointer to $04 and $05
	STA <$05	
	LDY #0	
	LDX #0
P32Loop:
	LDA [$0004],Y	
	PHA ; get left nybble
	AND #$F0
	LSR A
	LSR A
	LSR A
	LSR A
	STA $2007	
	PLA ; get right nybble
	AND #$0F
	STA $2007
	LDA $2007 ; add a space
	INX
	CPX #08
	BNE P32SkipADDR
	LDX #0
	LDA <$03
	CLC
	ADC #$20
	STA <$03
	BCC P32SkipADDRHi
	INC <$02
P32SkipADDRHi:
	LDA <$02
	STA $2006
	LDA <$03
	STA $2006
P32SkipADDR:
	INY
	CPY #32
	BNE P32Loop
	; post loop
	LDY #02
	JSR FixRTS
	RTS
;;;;;;;

PrintCHR:	; Pretty much the same thing as "PrintText" but don't convert from ASCII.
	LDA <dontSetPointer
	BNE PChr_dontSetPointer
	JSR CopyReturnAddressToByte0
	LDY #1
	LDA $2002
	LDA [$0000],Y ; Read from the pointer
	STA <$03
	DEY
	LDA [$0000],Y
	STA <$04
	LDA #02
	JSR AddAToByte0
PChr_dontSetPointer:
	LDA <$03
	STA $2006
	LDA <$04
	STA $2006
PChrloop:
	LDA [$0000],Y
	CMP #$FF
	BEQ PChrpostLoop
	STA $2007
	INY
	BNE PChrloop ; Branch always to the loop
PChrpostLoop:	
	INY
	LDA <dontSetPointer
	BNE PChrskipFixRTS
	JSR FixRTS
PChrskipFixRTS:
	RTS
;;;;;;;

InitializeSpriteZero:	; Sets address $200 through $203 to the values found in the 4 bytes following the JSR to this subroutine.
	; This also adjusts the return address.
	JSR CopyReturnAddressToByte0
	LDY #0
InitializeSpriteZeroLoop:
	LDA [$0000],Y
	STA $200,Y
	INY
	CPY #4
	BNE InitializeSpriteZeroLoop
	JSR FixRTS
	RTS
;;;;;;;

InitializeSpriteX:	; Sets address $200+X*4 through $203+X*4 to the values found in the 4 bytes following the JSR to this subroutine.
	; This also adjusts the return address.
	JSR CopyReturnAddressToByte0
	LDA #$02
	STA <$03
	TXA
	ASL A
	ASL A
InitializeSpriteReUseThisForOAMAddrX:
	STA <$02
	LDY #0
InitializeSpriteXLoop:
	LDA [$0000],Y
	STA [$0002],Y
	INY
	CPY #4
	BNE InitializeSpriteXLoop
	JSR FixRTS
	RTS
;;;;;;;

InitializeOAMAddrX:; Sets address $200+X through $203+X to the values found in the 4 bytes following the JSR to this subroutine.
	; This also adjusts the return address.
	JSR CopyReturnAddressToByte0
	LDA #$02
	STA <$03
	TXA
	JMP InitializeSpriteReUseThisForOAMAddrX
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

Read32NametableBytes:	; This is ran immediately after power on, and these values are stored for future printing in the "VRAM at power on" test.
	LDA #$2C
	STA $2006
	LDA #$00
	STA $2006
	LDA $2007	
	LDX #0
ReadNametableLoop:	
	LDA $2007
	STA PowerOnVRAM, X
	INX
	CPX #$20
	BNE ReadNametableLoop
	RTS
;;;;;;;

ReadPaletteRAM: ; This is ran immediately after power on, and these values are stored for future printing in the "Palette RAM at power on" test.
	LDA #$3F
	STA $2006
	LDA #$00
	STA $2006	
	LDX #0
ReadPalLoop:	
	LDA $2007
	STA PowerOnPalette, X
	INX
	CPX #$20
	BNE ReadPalLoop
	RTS
;;;;;;;

DefaultPalette:	; The default palette for the main menu.
	.byte $2D,$2D,$30,$30,$0F,$00,$30,$21,$0F,$26,$26,$26,$0F,$2D,$2D,$0F
	.byte $2D,$30,$30,$30,$0F,$30,$30,$30,$0F,$30,$30,$30,$0F,$26,$26,$26
AllTestMenuPalette:	; The color palette used in the results screen of the all-test-menu.
	.byte $2D,$30,$30,$30,$0F,$21,$21,$21,$0F,$26,$26,$26,$0F,$26,$06,$21
	.byte $2D,$30,$30,$30,$0F,$31,$31,$31,$0F,$30,$30,$30,$0F,$30,$30,$30	
SetUpAllTestMenuPalette:
	LDY #$20
	.byte $9D ; CMP Absolute (skip the upocoming LDY)
SetUpDefaultPalette: ; This function overwrites palette RAM with the values in the above table.
	LDY #0
	LDA #$3F
	STA $2006
	LDA #$00
	STA $2006
	LDX #0
SetUpPaletteLoop:
	LDA DefaultPalette,Y
	STA $2007
	INY
	INX
	CPX #32
	BNE SetUpPaletteLoop
	RTS
;;;;;;;
	
CopyReturnAddressToByte0: ; Several helper functions have a series of bytes following them that need to be read to adjust how the function runs.
	; For instance, JSR PrintText has a .word, and a string+terminator following a .byte
	; This function just takes the return address from the previous JSR instruction, adds 1 to it, and stores both bytes in a word at address $0000
	; That way, you can easily run LDA [$0000], Y to read the bytes that followed the JSR instruction.
	; NOTE: This will corrupt the stack. see FixRTS below.
	; NOTE: If your emulator pushes the wrong return address from RTS, this function will still work, as it was detected and stored in IncorrectReturnAddressOffset.
	PLA
	STA <$02
	PLA
	STA <$03
	PLA
	STA <$00
	PLA
	STA <$01
	LDA <$00
	SEC
	SBC <IncorrectReturnAddressOffset
	STA <$00
	INC <$00 ; INC the low byte
	BNE CPYRTS0
	INC <$01 ; If needed, INC the high byte
CPYRTS0:	
	LDA <$03
	PHA
	LDA <$02
	PHA
	RTS
;;;;;;;

AddAToByte0: ; This function adds the A register to the word at $0000
	; Since many functions pull the return address off and store values at address $0000, it's very convenient to add a number to the word at $0000 
	CLC
	ADC <$00
	STA <$00
	BCC ADDRTS0
	INC <$01 ; If needed, INC the high byte
ADDRTS0:
	RTS
;;;;;;;

FixRTS:	; Correct the return address so any stack modifications for other functions won't cause issues
	PLA ; pull off the current return address	
	STA <$02
	PLA
	STA <$03 
	DEY ; the RTS address needs to be -1 of the following instruction.
	TYA
	JSR AddAToByte0
	LDA <$01 ; add Byte0 to the return stack
	PHA
	LDA <$00
	CLC
	ADC <IncorrectReturnAddressOffset
	PHA
	LDA <$03 ; add back the return address from this function
	PHA
	LDA <$02
	PHA
	RTS
;;;;;;;

LoadSuiteMenuNoRendering:	; This only sets up the pointers for tests and results, as well as menuHeight, without any updates to the nametable. Used in the "run every test in the ROM" subroutine.
	STY <Copy_Y
	JSR LSM_CopySuitePointerToByte0
	; Address $0000 is now the suite pointer.
	LDY #0
	; The first part of a suite is the name, which we aren't rendering here, so let's keep looking until we find $FF.
LSMNR_Loop1:
	LDA [$0000], Y
	INY
	CMP #$FF
	BNE LSMNR_Loop1
	JSR LSM_AddYToSuitePointer
	; Now that we're past the name of the suite, we need to loop over every entry for a page.
	; the format is: Name, $FF, ResultPointer, TestPointer
	; If the first byte of Name is $FF, then we loaded everything in a page.
	LDX #0
	STX <Copy_X
LSMNR_Loop2:
	LDY #0
	JSR LSM_CopySuitePointerToByte0
	; Check if we're done with the page.
	LDA [$0000], Y
	CMP #$FF
	BNE LSMNR_SkipExit
	LDA <Copy_X
	LSR A
	STA <menuHeight
	LDY <Copy_Y
	RTS	
LSMNR_SkipExit:
	; Alright, let's skip this string.
	LDY #0
LSMNR_Loop3:
	LDA [$0000], Y
	INY
	CMP #$FF
	BNE LSMNR_Loop3
	JSR LSM_AddYToSuitePointer
	JSR LSM_CopySuitePointerToByte0
	LDY #0
	LDX <Copy_X
	JSR LSM_ReadSuiteRow
	INX	
	STX <Copy_X
	; Y = 4.
	JSR LSM_AddYToSuitePointer
	JMP LSMNR_Loop2
;;;;;;;;;;;;;;;;;;;

LSM_ReadSuiteRow:
	LDA [$0000], Y
	STA <suitePointerList, X
	INY
	INX
	LDA [$0000],Y
	STA <suitePointerList, X
	INY
	DEX
	LDA [$0000],Y
	STA <suiteExecPointerList, X
	INY
	INX
	LDA [$0000],Y
	STA <suiteExecPointerList, X
	INY
	RTS
;;;;;;;

LSM_AddYToSuitePointer:
	TYA
	CLC
	ADC <suitePointer
	STA <suitePointer
	BCC LSM_AddYSkipInc
	INC <suitePointer+1
LSM_AddYSkipInc:
	RTS
;;;;;;;

LoadSuiteMenu: ; Print a list of tests to run. If these tests have been ran before, print the results too!
	; assume the beginning of the suite is currently stored at suitePointer
	; print the name of the suite.
	; set up the PPU address to $2070	
	LDA #$20
	STA <$03
	LDA #$70
	STA <$04
	LDA #01
	STA <dontSetPointer
	;suitepointer is already set up, so...
	JSR LSM_CopySuitePointerToByte0
	JSR PrintTextCentered
	; set up the PPU address to $20A8
	LDA #$20
	STA <$03
	LDA #$A8
	STA <$04
	LDX #0
LSM_Loop:
	; add Y to suitePointer
	JSR LSM_AddYToSuitePointer
	LDA <$04
	CLC
	ADC #$40
	STA <$04
	BCC LSM_SkipInc2
	INC <$03
LSM_SkipInc2:
	JSR LSM_CopySuitePointerToByte0
	LDY #0
	LDA [$0000],Y
	CMP #$FF
	BNE LSM_DontExitLoop
	TXA
	LSR A
	STA menuHeight
	RTS
LSM_DontExitLoop:
	JSR PrintText
	; then store the test results pointer
	JSR LSM_ReadSuiteRow
	DEX	
	; let's also update the attribute tables before prepping X for the next loop.
	TXA
	PHA
	LSR A
	TAX
	JSR DrawTEST	

	JSR UpdateTESTAttributes
	PLA
	TAX
	INX
	INX	
	JMP LSM_Loop
;;;;;;;;;;;;;;;;
	
DrawTEST:	; This will print "TEST", "PASS", "FAIL x" or "...." depending on if the test has yet to be ran, passed, failed, or currently in progress.
	STY <$FE
	STX <$FD
	; relocate the PPU v register
	JSR GetVRegisterByXIndexForMenu
	; read the test results
	TXA
	ASL A
	TAX	
	LDY #4
	LDA <suitePointerList+1,X ; check if we're using page 3 or page 4 for these results.
	CMP #3
	BNE DrawTEST_NotDRAW
	LDA #4
	BNE DrawTEST_Print ; Branch always.
DrawTEST_NotDRAW: ; some tests say "DRAW" instead of "TEST". These say "TEST" though.
	LDA [suitePointerList,X]
	CMP #$FF ; If the error code is $FF, we skip this test in the all-test-mode.
	BNE DrawTEST_NotSkip
	LDA #5
	BNE DrawTEST_Print ; Branch always.
DrawTEST_NotSkip:
	STA <ErrorCode
	; 0 = "TEST"
	; 1 = "PASS"
	; 2 = "FAIL"
	; 3 = "...." for a test in progress.
	; 4 = "DRAW"
	; 5 = "SKIP"
	;;;;;;;;;;;;
	AND #$3 ; bits 0 and 1 hold the results. Bits 3+ hold error codes for printing what failed.
DrawTEST_Print:
	TAX
	TAY
	LDA TestPassFailBlend,Y
	JSR DrawTEST_PrintStep
	LDA TestPassFailBlend+6,Y
	JSR DrawTEST_PrintStep
	LDA TestPassFailBlend+12,Y
	JSR DrawTEST_PrintStep
	LDA TestPassFailBlend+18,Y
	JSR DrawTEST_PrintStep
	AND #$3
	CMP #2 ; check if we failed.
	BNE DrawTESTEraseErrorCode
	; we failed, so print an error code.
	LDA #$24
	STA $2007
	LDA <ErrorCode
	AND #$FC
	LSR A
	LSR A
DrawTESTEnd:
	STA $2007	
	LDY <$FE
	LDX <$FD
	RTS
DrawTESTEraseErrorCode:
	LDA #$24
	STA $2007
	BNE DrawTESTEnd
;;;;;;;

DrawTEST_PrintStep:
	TAY
	LDA AsciiToCHR-32,Y
	STA $2007
	TXA
	TAY
	RTS
;;;;;;;



UpdateTESTAttributes: ; This will update the attributes for the test results "PASS", or "FAIL x", so they can be colored differently.
	STY <$FE
	STX <$FD
	TXA
	ASL A
	TAX
	LDA <suitePointerList+1,X ; check if we're using page 3 or page 4 for these results.
	LDX <$FD
	CMP #3
	BNE UpdateTESTAttributes_NotDRAW	
	RTS
UpdateTESTAttributes_NotDRAW:
	; convert the x value to the attribute address, and determine top/bottom.
	LDA #$23
	STA <byte8
	STA $2006
	INX
	TXA
	AND #$FE
	; n = ((x+1)/2)
	ASL A
	ASL A
	; n *= 8
	CLC
	ADC #$C8
	; $23c8 + n
	STA <byte9
	STA $2006	
	LDA $2007
	LDA $2007
	STA <suiteAttributeCopy
	LDA $2007
	STA <suiteAttributeCopy+1
	LDA <byte8
	STA $2006
	LDA <byte9
	STA $2006
	; is this top or bottom?
	DEX
	TXA
	AND #01
	TAY
	LDA AttributeNybblesInverse, Y
	AND <suiteAttributeCopy
	STA <suiteAttributeCopy
	LDA AttributeNybblesInverse, Y
	AND <suiteAttributeCopy+1
	STA <suiteAttributeCopy+1
	
	; read the test results
	LDX <$FD
	TXA
	CMP #$FF
	BNE UpdateTESTAttributes_NotSkip
	LDA #$03
	BNE UpdateTESTAttributes_Print
UpdateTESTAttributes_NotSkip:
	ASL A
	TAX	
	LDA [suitePointerList,X]
	AND #3
UpdateTESTAttributes_Print:
	TAX	
	; the palette will be the results.
	LDA AttributePaletteNybbles,X
	AND AttributeNybbles, Y
	ORA <suiteAttributeCopy
	STA <suiteAttributeCopy
	LDA AttributePaletteNybbles,X
	AND AttributeNybbles, Y
	ORA <suiteAttributeCopy+1
	STA <suiteAttributeCopy+1
	
	LDA <suiteAttributeCopy
	STA $2007
	LDA <suiteAttributeCopy+1
	STA $2007
	
	LDY <$FE
	LDX <$FD
	RTS
;;;;;;;

HighlightTest:	; Swaps the characters on the nametable from the unhighlighted version to the highlighted version, or vice versa. (flip bit 7)
	JSR GetVRegisterByXIndexForMenu
	LDA $2007
	LDY #$00
CopyTestTextLoop:
	LDA $2007
	STA TESTHighlightTextCopy,Y
	INY
	CPY #$04
	BNE CopyTestTextLoop
	JSR GetVRegisterByXIndexForMenu
	LDY #$00
HighlightLoop:
	LDA TESTHighlightTextCopy,Y
	EOR #$80
	STA $2007
	INY
	CPY #$04
	BNE HighlightLoop
	RTS
;;;;;;;

HighlightPageNumber:	; Swaps the characters on the nametable from the unhighlighted version to the highlighted version, or vice versa. (flip bit 7)
	JSR SetPPUADDRFromWord
	.byte $20, $AA
	LDA $2007
	LDY #$00
HighlightPageNumberLoop:
	LDA $2007
	STA $7F0,Y ; this will get cleared before any tests run, so I don't feel bad for using these bytes here,
	INY
	CPY #$0C
	BNE HighlightPageNumberLoop
	JSR SetPPUADDRFromWord
	.byte $20, $AA
	LDY #$00
HighlightPageTextLoop:
	LDA $7F0,Y ; this will get cleared before any tests run, so I don't feel bad for using these bytes here,
	EOR #$80
	STA $2007
	INY
	CPY #$0C
	BNE HighlightPageTextLoop
	RTS
;;;;;;;

GetVRegisterByXIndexForMenu: ; Sets up the PPU's "v" register to print the name of the test at the right position, based on index X into the suite.
	; $20E1 + $40*X
	; High = ((X+3) >> 2) + 20
	TYA
	PHA
	TXA
	CLC
	ADC #$03
	LSR A
	LSR A
	CLC
	ADC #$20
	STA $2006
	; Low = VRegisterByXIndexLowLUT[X&3]
	TXA
	AND #$03
	TAY
	LDA VRegisterByXIndexLowLUT,Y
	STA $2006
	PLA
	TAY
	RTS
;;;;;;;

ReadPPUADDRFromWord: ; Takes the two bytes after the JSR instruction and stores them in $2006. Then reads $2007 twice.
	STY <$FE
	JSR CopyReturnAddressToByte0
	LDA $2002
	LDY #0
	LDA [$0000],Y
	STA $2006
	INY
	LDA [$0000],Y
	STA $2006
	INY
	JSR FixRTS
	LDY <$FE
	LDA $2007
	LDA $2007
	RTS
;;;;;;;
SetPPUADDRFromWord:	; pretty much the same as ReadPPUADDRFromWord, but it doesn't run LDA $2007 twice at the end.
	STA <$FF
	STY <$FE
	JSR CopyReturnAddressToByte0
	; Good practices would dictate a read of $2002 here to reset the w register.
	; However, there are rare situations where I wish to use this subroutine without clearing the vblank flag.
	LDY #0
	LDA [$0000],Y
	STA $2006
	INY
	LDA [$0000],Y
	STA $2006
	INY
	JSR FixRTS
	LDY <$FE
	LDA <$FF
	RTS
;;;;;;;
WriteToPPUADDRWithByte:	; Sets up v then writes n to it, where n is the third byte after the JSR
	STA <$FF
	STY <$FE
	JSR CopyReturnAddressToByte0
	LDA $2002
	LDY #0
WriteToPPUADDRWithByteLoop:
	LDA [$0000],Y
	CMP #$FF
	BEQ WriteToPPUADDRWithByteExit
	STA $2006
	INY
	LDA [$0000],Y
	STA $2006
	INY
	LDA [$0000],Y
	STA $2007
	INY
	JMP WriteToPPUADDRWithByteLoop
WriteToPPUADDRWithByteExit:
	INY
	JSR FixRTS
	LDY <$FE
	LDA <$FF
	RTS
;;;;;;;

DoubleLDA2007:	; There are a few tests that need to read the contents of a PPU address.
	LDA $2007	; and instead of actually writing out LDA $2007 twice (6 bytes)
	LDA $2007	; you can just jump here instead. (3 bytes)
	RTS
;;;;;;;

SetPPUReadBufferToA: ; Sets the value of the PPU Read buffer to A.
	PHA
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	STA $2007
	JSR SetPPUADDRFromWord
	.byte $2C, $00
	LDA $2007
	PLA
	RTS
;;;;;;;

PrepNMI_TimingTests: ; This is re-used in a handful of NMI timing tests.
	LDA #$C8	; INY opcode
	STA $700
	LDA #$40	; RTI opcode
	STA $701
	JSR DisableRendering
	LDX #0
	RTS
;;;;;;;


VRegisterByXIndexLowLUT:	; a look up table used in GetVRegisterByXIndexForMenu
	.byte $E1, $21, $61, $A1

AttributeNybbles:			; Attribute nybbles used in UpdateTESTAttributes
	.byte $F0, $0F
AttributeNybblesInverse:	; Attribute nybbles used in UpdateTESTAttributes
	.byte $0F, $F0
	
AttributePaletteNybbles:	; Attribute nybbles used in UpdateTESTAttributes
	.byte $00, $55, $AA, $FF
	
TestPassFailBlend:			; These are used in DrawTEST. index 0 of each of these spells "TEST". index 1 spells "PASS" and so on.
	.byte "TPF.DS"
	.byte "EAA.RK"
	.byte "SSI.AI"
	.byte "TSL.WP"

NMI_Routine:
	; This is the NMI routine for the main menu.
	JSR ReadController1
	JSR MaskDpadConflicts
	LDA <controller_New
	AND #$20
	BNE NMI_DoDebugStuff
	JMP NMI_NotPressingSelect
NMI_DoDebugStuff:
	; Enter or exit debug mode.
	LDA <DebugMode
	BEQ NMI_EnterDebugMode
	; exiting debug mode.
	LDA #0
	STA <DebugMode
	LDA <PPUCTRL_COPY
	AND #$EF
	STA <PPUCTRL_COPY	; the tiles will use pattern table 2.
	STA $2000
	JSR SetPPUADDRFromWord
	.byte $20, $00
	LDA <PPUMASK_COPY
	AND #$FE
	STA <PPUMASK_COPY
	STA $2001
	JMP NMI_NotPressingSelect
NMI_EnterDebugMode:
	LDA #1
	STA <DebugMode
	LDA <PPUCTRL_COPY
	ORA #$10
	STA <PPUCTRL_COPY ; the tiles will use pattern table 1.
	STA $2000
	JSR DisableRendering
	JSR DisableNMI
	JSR ClearNametable2
	JSR SetPPUADDRFromWord
	.byte $2D, $00
	LDX #0
NMI_EnterDebugModeLoop:
	LDA $500,X
	STA $2007
	INX
	BNE NMI_EnterDebugModeLoop
NMI_EnterDebugModeLoop1:
	LDA $600,X
	STA $2007
	INX
	BNE NMI_EnterDebugModeLoop1
	JSR SetPPUADDRFromWord
	.byte $2C, $A0
	LDX #0
NMI_EnterDebugModeLoop2:
	LDA <$50,X
	STA $2007
	INX
	CPX #$20
	BNE NMI_EnterDebugModeLoop2
	BNE NMI_EnterDebugModeLoop
	JSR SetPPUADDRFromWord
	.byte $2C, $80
	LDX #0
NMI_EnterDebugModeLoop3:
	LDA <$20,X
	STA $2007
	INX
	CPX #$10
	BNE NMI_EnterDebugModeLoop3
	JSR SetPPUADDRFromWord
	.byte $2F, $C0
	; set up attribute bytes.
	LDX #0
	LDA #$FF
NMI_EnterDebugModeLoop4:
	STA $2007
	INX
	CPX #$8
	BNE NMI_EnterDebugModeLoop4
	; next 8, write #F0
	LDA #%11110001
NMI_EnterDebugModeLoop5:
	STA $2007
	INX
	CPX #$10
	BNE NMI_EnterDebugModeLoop5
	; next 32, write #00
	LDA #%00010100
NMI_EnterDebugModeLoop6:
	STA $2007
	INX
	CPX #$30
	BNE NMI_EnterDebugModeLoop6
	; next 8, write #FF again
	LDA #$FF
NMI_EnterDebugModeLoop7:
	STA $2007
	INX
	CPX #$40
	BNE NMI_EnterDebugModeLoop7
	JSR WaitForVBlank
	LDA <PPUMASK_COPY
	ORA #$0A
	STA <PPUMASK_COPY
	STA $2001
	JSR EnableNMI
	JSR SetPPUADDRFromWord
	.byte $2C, $00	
	LDA #0
	STA $2005
	STA $2005
	
NMI_NotPressingSelect:
	LDA <DebugMode
	BEQ NMI_Continue

	RTI	; skip the JSR ResetScroll when in debug mode.
NMI_Continue:
	LDA <menuCursorYPos
	LDX <menuCursorYPos
	BMI NMI_Menu_CursorAtTop
	; cursor is not at the top.
	LDA <controller_New
	AND #$80 ; A
	BEQ NMI_Menu_NotBeginningTest
	; Run test!
	JSR RunTest	
	JMP ExitNMI
NMI_Menu_NotBeginningTest:
	LDA <controller_New
	AND #$40 ; B
	BEQ NMI_Menu_NotSkippingTest
	; Run test!
	JSR MarkTestToSkip	
	JMP ExitNMI
NMI_Menu_NotSkippingTest:
	LDA <controller_New
	AND #$04 ; Down
	BEQ NMI_Menu_NotMovingDown
	INC <menuCursorYPos
	LDA <menuCursorYPos
	CMP <menuHeight
	BNE NMI_Menu_DownNotAtLength
	DEC <menuCursorYPos ; menuCursorYPos = menuHeight-1;
NMI_Menu_DownNotAtLength:
	JSR HighlightTest
	LDX <menuCursorYPos
	JSR HighlightTest
	JMP ExitNMI
	;;;
NMI_Menu_NotMovingDown:
	LDA <controller_New
	AND #$08 ; Up
	BEQ NMI_Menu_NotMovingUp
	; move cursor up
	DEC <menuCursorYPos
	JSR HighlightTest
	LDX <menuCursorYPos
	BMI NMI_Menu_DontPokeTextAgain
	JSR HighlightTest
NMI_Menu_NotMovingUp:
	JMP ExitNMI
NMI_Menu_DontPokeTextAgain:
	JSR HighlightPageNumber	; highlight the "page xx of yy" text.
	JMP ExitNMI
	
	;;;
NMI_Menu_CursorAtTop
	; cursor is at the top. if we press left or right, swap in a different set
	LDA <controller_New
	AND #$01 ; right
	BEQ NMI_Menu_Top_NotPressingRight
	; pressing Right
	LDA <menuTabXPos
	CMP #((EndTableTable - TableTable)/2)-1
	BNE NMI_Menu_SwapSuiteRight_SkipReset
	LDA #$FF
	STA <menuTabXPos
NMI_Menu_SwapSuiteRight_SkipReset:	
	INC <menuTabXPos	
	JSR DrawNewSuiteTable
	JMP ExitNMI
	
NMI_Menu_Top_NotPressingRight:
	LDA <controller_New
	AND #$02 ; left
	BEQ NMI_Menu_Top_NotPressingLeft
	; pressing Left
	LDA <menuTabXPos
	BNE NMI_Menu_SwapSuiteLeft_SkipReset
	LDA #((EndTableTable - TableTable)/2)
	STA <menuTabXPos
NMI_Menu_SwapSuiteLeft_SkipReset:
	DEC <menuTabXPos
	JSR DrawNewSuiteTable
	JMP ExitNMI	
	
NMI_Menu_Top_NotPressingLeft:
	; pressing down moves the cursor to 0.
	LDA <controller_New
	AND #$04 ; down
	BEQ NMI_Menu_Top_NotPressingDown
	LDA #0
	STA <menuCursorYPos
	LDX #0
	JSR HighlightTest
	JSR HighlightPageNumber	; unhighlight it.
NMI_Menu_Top_NotPressingDown:
	; If we press A, let's run every test in the suite automatically!
	LDA <controller_New
	AND #$80 ; A
	BEQ NMI_Menu_Top_NotPressingA
	JSR AutomaticallyRunEveryTestInSuite
NMI_Menu_Top_NotPressingA:
	; If we press B, let's mark every test in the suite to be skipped!
	LDA <controller_New
	AND #$40 ; B
	BEQ NMI_Menu_Top_NotPressingB
	JSR MarkEveryTestInSuiteToSkip
NMI_Menu_Top_NotPressingB:
	; If we press Start, let's run every test in the ROM!
	LDA <controller_New
	AND #$10 ; Start
	BEQ NMI_Menu_Top_NotPressingStart
	JSR AutomaticallyRunEveryTestInROM
	RTI
NMI_Menu_Top_NotPressingStart:
ExitNMI:
	JSR ResetScroll
	RTI
;;;;;;;

AutomaticallyRunEveryTestInSuite: ; This subroutine is used to run every test on a page automatically.
	LDA #1
	STA <AutomateTestSuite        ; The "AutomateTestSuite" variable is used to prevent awkward highlighting of the test results.
	JSR DisableNMI                ; Disable the NMI, since we're not going to want any extra NMI's running in the middle of this.
	LDX #0
AutomaticallyRunEveryTestLoop:    ; This loop runs once per test on a page.
	STX <menuCursorYPos           ; The "menuCursorYPos" variable is used inside RunTest to determine what code to run.
	JSR RunTest                   ; Run the test at this index into the page.
	INX                           ; increment X until X=MenuHeight.
	CPX <menuHeight               ; The "menuHeight" is just how many tests are on a page.
	BNE AutomaticallyRunEveryTestLoop
	LDA #$FF
	STA <menuCursorYPos           ; A "menuCursorYPos" of $FF is the top of the menu. (Highlighting the page number)
	LDA #0
	STA <AutomateTestSuite        ; Disable the "AutomateTestSuite" variable.
	JSR ResetScroll               ; Reset the PPU scroll.
	JSR EnableNMI                 ; And enable the MNI.
	RTS
;;;;;;;

MarkEveryTestInSuiteToSkip:
	LDA #1
	STA <AutomateTestSuite        ; The "AutomateTestSuite" variable is used to prevent awkward highlighting of the test results.
	JSR DisableNMI                ; Disable the NMI, since we're not going to want any extra NMI's running in the middle of this.
	JSR DisableRendering
	LDX #0
MarkEveryTestInSuiteToSkipLoop:    ; This loop runs once per test on a page.
	STX <menuCursorYPos           ; The "menuCursorYPos" variable is used inside RunTest to determine what code to run.
	JSR MarkTestToSkip                   ; Run the test at this index into the page.
	INX                           ; increment X until X=MenuHeight.
	CPX <menuHeight               ; The "menuHeight" is just how many tests are on a page.
	BNE MarkEveryTestInSuiteToSkipLoop
	LDA #$FF
	STA <menuCursorYPos           ; A "menuCursorYPos" of $FF is the top of the menu. (Highlighting the page number)
	LDA #0
	STA <AutomateTestSuite        ; Disable the "AutomateTestSuite" variable.
	JSR ResetScroll               ; Reset the PPU scroll.
	JSR WaitForVBlank
	JSR EnableNMI                 ; And enable the MNI.
	JSR EnableRendering_BG
	RTS
;;;;;;;

SetUpSuitePointer:
	LDA <menuTabXPos
	ASL A
	TAX	
	LDA TableTable,X
	STA <suitePointer
	LDA TableTable+1,X
	STA <suitePointer+1
	RTS
;;;;;;;

DrawNewSuiteTable:	; Draws and prepares the suite, menuTabXPos
	JSR DisableNMI
	JSR DisableRendering
	JSR ClearNametable
	JSR SetUpSuitePointer
	JSR LoadSuiteMenu
	
	JSR DrawPageNumber
	
	; wait for VBlank.
	JSR WaitForVBlank	
	JSR EnableRendering_BG
	JSR EnableNMI
	RTS
;;;;;;;

DrawPageNumber: ; Print "page xx / yy" at the top of the suite.	
	LDA #1
	STA <HighlightTextPrinted
	LDA #00
	STA <dontSetPointer
	JSR PrintText
	.word $20AA
	.byte "Page xx / yy", $FF
	JSR SetPPUADDRFromWord
	.byte $20, $AF
	LDA <menuTabXPos
	CLC
	ADC #1
	CMP #$0A
	BPL DNST_DontAdjustV
	LDA #$A4
	STA $2007
	LDA <menuTabXPos
	CLC
	ADC #1
DNST_DontAdjustV:
	JSR PrintByteDecimal_MinDigits
	JSR SetPPUADDRFromWord
	.byte $20, $B4
	LDA #((EndTableTable - TableTable)/2)
	JSR PrintByteDecimal_MinDigits
	LDA #0
	STA <HighlightTextPrinted
	RTS
;;;;;;;
	
WaitForVBlank:	; This loops until VBlank begins. (updates the VBLank flag of $2002 to be cleared before returning)
	LDA $2002
WaitForVblLoop:
	LDA $2002
	BPL WaitForVblLoop
	RTS
;;;;;;;

ResetScrollAndWaitForVBlank:	; Resets the scroll and then waits for VBlank.
	JSR ResetScroll
	JSR WaitForVBlank
	RTS
;;;;;;;

ReadController1:	; Some "proper" controller reading routine. Should work properly on Famicom as well as NES.
	LDA <controller
	STA <controller_New
	LDA #$01
	STA $4016
	LSR A
	STA $4016
	LDX #$08
RC_Loop:
	LDA $4016
	LSR A
	ROL <controller
	DEX
	BNE RC_Loop
	LDA <controller
	EOR <controller_New
	AND <controller
	STA <controller_New
	RTS
;;;;;;;

ReadControllerInto50_and_A:	; Reads controller port 1 8 times, storing the result in address 50, and also the A register.
	LDX #8	; We're going to read from the controller port 8 times.
ReadControllerInto50_Loop:
	LDA $4016	; This reads the controller port.
	LSR A		; This shifts bit 0 into the carry flag.
	ROL <$50	; and this rotates the carry flag into bit 0 of address $50.
	DEX			; decrement X until X=0
	BNE ReadControllerInto50_Loop
	LDA <$50	; And for good measure, let's load A with the result.
	RTS
;;;;;;;

MaskDpadConflicts:	; If you are holding both left + right, cancel them out. The same applies for up + down,
	LDA <controller
	AND #$F0
	STA <byteF
	LDA <controller
	AND #$0F
	TAY
	LDA DpadConflictMask,Y
	ORA <byteF
	STA <controller
	LDA <controller_New
	AND #$F0
	STA <byteF
	LDA <controller_New
	AND #$0F
	TAY
	LDA DpadConflictMask,Y
	ORA <byteF
	STA <controller_New
	RTS
;;;;;;;
	
DpadConflictMask: ; A LUT for masking the d-pad values.
	.byte $00, $01, $02, $00, $04, $05, $06, $00, $08, $09, $0A, $08, $00, $01, $02, $00

RunTest:
	; This function sets things up, then runs the test.
	; Basically, this makes a bunch of preparations for tests, like clearing page 5 of RAM, halting the NMI, etc.
	STA <Copy_A2                  ; Store the A register
	STY <Copy_Y2                  ; Store the Y register
	STX <Copy_X2                  ; Store the X register
	LDA <RunningAllTests
	BNE RunTest_AllTestSkipNMI    ; If we're currently running all tests the NMI is already disabled, so we don't need to write to $2000 
	JSR DisableNMI	              ; We don't want the NMI occurring during the tests. (and if we do, overwrite the NMI function in RAM before enabling it)
RunTest_AllTestSkipNMI:
	LDX <menuCursorYPos           ; X = which test from the current suite we're running
	TXA
	ASL A                         ; Double X, since we're reading a 2-byte word from a list of 2-byte words.
	TAX
	LDA <suiteExecPointerList,X   ; read the low byte of where the test occurs.
	STA <testAddressPointer       ; and store it in RAM for an indirect JMP.
	LDA <suiteExecPointerList+1,X ; read the high byte of where the test occurs.
	STA <testAddressPointer+1     ; and store it in RAM next to the low byte.
	LDA <suitePointerList,X	      ; read the low byte of where to store the test results.
	STA <TestResultPointer        ; and store it in RAM
	LDA <suitePointerList+1,X     ; read the high byte of where to store the test results.
	STA <TestResultPointer+1      ; and store it in RAM next to the low byte.
	
	LDA <TestResultPointer+1      ; draw tests cannot be marked to be skipped,
	CMP #3                        ; but address $3FF is uninitialized, and might be $FF. 
	BEQ RunTest_SkipSkip          ; So we make sure we never skip Draw tests.
	
	LDY #0                        ; set up Y for the upcoming indirect reads.
	LDA [TestResultPointer],Y     ; check if this test is marked to be skipped.
	CMP #$FF                      ; If the "test results" are $FF, we skip this one.
	BNE RunTest_SkipSkip          ; If we aren't skipping tests, jump over these next few lines.
	JSR ResetScrollAndWaitForVBlank; Wait for vblank, otherwise skipping many tests causes enough time for vblank to end before a future test attempts to draw their status.
	LDA <RunningAllTests
	BNE RunTest_AllTestSkipSkip
	JSR EnableNMI                 ; Enable NMI. (Wait for VBlank pokes $2002, so the NMI doesn't happen here.)
RunTest_AllTestSkipSkip:
	JSR EnableRendering_BG	      ; enable rendering the background. (If skipping the first test in the all-test-mode, the screen would otherwise be blanked until the first non-skipped test.)
	LDY <Copy_Y2                  ; Restore the Y register
	LDX <Copy_X2                  ; Restore the X register
	LDA <Copy_A2                  ; Restore the A register
	RTS                           ; RTS.
	
RunTest_SkipSkip:
	LDA <RunningAllTests          ; Check if this is in the all-test mode.
	BNE RunTest_AllTestSkipDraw1  ; If so, skip updating the status.
	LDA #3	                      ; a value of 3 here is used to draw "...." as the test status.
	STA [TestResultPointer],Y     ; mark this test as "in progress"
	LDX <menuCursorYPos           ; load X for the upcoming subroutines.
	JSR DrawTEST                  ; replace the word "TEST" with "...."
	JSR HighlightTest             ; and highlight it, since the cursor is still here.
	JSR ResetScroll               ; Reset the scroll before the test, since we just modified 'v' inside the previous subroutines.
RunTest_AllTestSkipDraw1:
	LDA #1
	STA <ErrorCode                ; set this to 1 before running any tests.
	STA <initialSubTest           ; Some tests have multiple sets of tests to run, all using the same code. So writing here changes the test value.
	LDA #$80
	STA <Test_UnOp_SP             ; Some tests might modify the stack pointer. The test will use a value of $80 just to be sure it's not overwriting other stack data.
	JSR ClearPage5                ; clear RAM from $500 to $5FF. That RAM is dedicated for running tests, so we want it clean.
	JSR ClearPage2                ; clear page 2 as well.
	LDA #0
	STA $2003                     ; tests must start with OAMADDR at 0
	JSR WaitForVBlank             ; this makes debugging your own emulator with this ROM much easier, since the test should always begin at the start of a frame.
	LDA #0                        ; Initialize A to 0.
	TAX                           ; Initialize X to 0.
	TAY                           ; Initialize Y to 0.
	JSR PerformTest               ; !! This is where the test occurs. !!
                                  ; The A Register holds the results of the test.
	LDY #0
	STA [TestResultPointer],Y     ; store the test results in RAM.
	STA <Copy_A
	LDA #0
	STA $4015                     ; Disable the DMC.
	LDA <RunningAllTests          ; Check if this is in the all-test mode.
	BNE RunTest_AllTestSkipDraw2  ; If so, skip updating the status.
	JSR DisableNMI	              ; If a test enabled the NMI and forgot to disable it, let's do that real quick before waiting for vblank.
	JSR WaitForVBlank             ; and wait for VBlank before updating the "...." text with the results.
	LDX <menuCursorYPos           ; load X for the upcoming subroutines.
	JSR DrawTEST                  ; draw "PASS" or "FAIL x"
	JSR UpdateTESTAttributes      ; and update the colors for that text.
	LDA <AutomateTestSuite
	BNE RunTest_SkipHighlightResult
	JSR HighlightTest             ; and also highlight it, as the cursor is still there.
RunTest_SkipHighlightResult:
	JSR SetUpNMIRoutineForMainMenu; Recreate the NMI routine JMP, since some tests need their own NMI routine.
	JSR EnableNMI                 ; With the test over, re-enable the NMI
RunTest_AllTestSkipDraw2:         ; If we're running all tests, we don't need the NMI to run.
	JSR DisableRendering_S        ; disable rendering sprites.
	JSR EnableRendering_BG        ; and enable rendering the background. This should still occur during Vblank.
	LDA #0
	STA <dontSetPointer
	LDY <Copy_Y2                  ; Restore the Y register
	LDX <Copy_X2                  ; Restore the X register
	LDA <Copy_A2                  ; Restore the A register
	RTS
;;;;;;;

;;; PerformTest ;;;
; This is an indirect jump. The test will end with an RTS, effective acting as the RTS for this routine.
PerformTest:                 ;
	LDX #0                   ;
	JMP [testAddressPointer] ; Move the PC to the location of the test.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

ClearNametableFrom2240:	; Some "tests" just print a bunch of values on screen around VRAM address $2240.
						; This function simply clears a good amount of VRAM from those tests.
	LDA #$22
	STA $2006
	LDA #$40
	STA $2006
	LDX #$10
	LDA #$24
ClearNTFrom2240Loop:	; I unrolled this loop to save CPU cycles, since I'd like all of this to happen inside VBlank, with time to spare to write more stuff.
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	STA $2007
	DEX
	BNE ClearNTFrom2240Loop
	RTS
;;;;;;;

ClearOverscanNametable:	; some tests draw tiles in the overscan area of the first nametable. This clears that.
	JSR WaitForVBlank
	JSR SetPPUADDRFromWord
	.byte $20, $00
	LDA #$24
	LDX #$32
ClearOverscanNametableLoop1:
	STA $2007
	DEX
	BNE ClearOverscanNametableLoop1
	JSR SetPPUADDRFromWord
	.byte $23, $A0
	LDA #$24
	LDX #32
ClearOverscanNametableLoop2:
	STA $2007
	DEX
	BNE ClearOverscanNametableLoop2
	JSR ResetScroll
	RTS
;;;;;;;


PrintByte:	; Takes the A register and prints each nybble separately as two characters on the nametable at the current "v" address.
	; This doesn't make any stack shenanigans.
	PHA
	PHA
	STX <Copy_X
	AND #$F0
	LSR A
	LSR A
	LSR A
	LSR A
	LDX <HighlightTextPrinted
	BEQ PB_SkipHighlight
	ORA #$80
PB_SkipHighlight:
	STA $2007
	PLA
	AND #$0F
	LDX <HighlightTextPrinted
	BEQ PB_SkipHighlight1
	ORA #$80
PB_SkipHighlight1:
	STA $2007
	LDX <Copy_X
	PLA
	RTS
;;;;;;;

PrintByteDecimal_MinDigits:	; Takes the A register and prints a decimal representation of that value on the nametable at the current "v" address. Removes trailing zeroes.
	; This doesn't make any stack shenanigans.
	PHA
	LDX #1
	STX <PrintDecimalTensCheck
	LDX #$FF
PBDMD_HundredsLoop:
	; Calculate the hundreds digit in decimal.
	INX
	SEC
	SBC #100
	BCS PBDMD_HundredsLoop
	; we underflowed. add 100 back.
	ADC #100
	PHA
	TXA
	BEQ PBDMD_SkipHundredsDigit
	INC <PrintDecimalTensCheck
	LDX <HighlightTextPrinted
	BEQ PBDMD_SkipHighlightHundreds
	ORA #$80
PBDMD_SkipHighlightHundreds:
	STA $2007
PBDMD_SkipHundredsDigit:
	DEC <PrintDecimalTensCheck
	PLA
	LDX #$FF
PBDMD_TensLoop:
	; Calculate the hundreds digit in decimal.
	INX
	SEC
	SBC #10
	BCS PBDMD_TensLoop
	; we underflowed. add 10 back.
	ADC #10
	PHA
	TXA
	; if both this value and PrintDecimalTensCheck are zero, don't print a zero here. Otherwise, the hundreds digit was printed, and we need to print a zero here.
	ORA <PrintDecimalTensCheck
	BEQ PBDMD_SkipTensDigit
	TXA
	LDX <HighlightTextPrinted
	BEQ PBDMD_SkipHighlightTens
	ORA #$80
PBDMD_SkipHighlightTens:
	STA $2007
PBDMD_SkipTensDigit:
	PLA
	LDX <HighlightTextPrinted
	BEQ PBDMD_SkipHighlightOnes
	ORA #$80
PBDMD_SkipHighlightOnes:
	STA $2007
	PLA
	RTS
;;;;;;;

SetUpNMIRoutineForMainMenu:	; This sets up the values at $700 in RAM to be a JMP to the main menu's NMI routine. (The NMI points to address $700)
	LDA #$4C
	STA $700
	LDA #Low(NMI_Routine)
	STA $701
	LDA #High(NMI_Routine)
	STA $702
	RTS
;;;;;;;

DMASync_50CyclesRemaining:	; Sync the CPU and the DMA, such that the DMA runs exactly 50 CPU cycles after the RTS instruction ends.
	JSR DMASync
	; On the 2A07 DMASync returns 322 cycles before the point (T0 + 400) from which the next DMA lands on the
	; first opcode fetch (see DMASyncWithoutOpenBus). 322 - 266 - 6 (this RTS) = 50.
	JSR ClockslideFromWord
	.word 266
	RTS ; 56 -> 50 cycles after this RTS, a DMA will occur.
	
DMASync_50MinusACyclesRemaining: ; Sync the CPU and the DMA, such that the DMA is requested a fixed number of cycles after the RTS.
	; Used by TEST_UnOp_DMANoEffect (SHA/SHX/SHY/SHS error codes 7-C), as the JSR hook at the start of the RAM function.
	; The 2A07 sync (DMASync) waits with ClockslideFromWord, which uses zero page $20/$21 and $FD-$FF: the
	; unofficial-opcode runner's target pointer and saved X. They are saved before the sync and restored after it, inside
	; the counted wait, so the instruction under test sees the same state as without the hook.
	; By count the request falls 49 - A cycles after the RTS (A = <Test_UnOp_CycleDelayPostDMA>): 322 - 227 - 3 - (37 + A) - 6.
	LDA <$20
	STA $06F0
	LDA <$21
	STA $06F1
	LDA <$FD
	STA $06F2
	JSR DMASync                      ; the request is 322 cycles away
	LDA $06F0                        ; 4
	STA <$20                         ; 7
	LDA $06F1                        ; 11
	STA <$21                         ; 14
	LDA $06F2                        ; 18
	STA <$FD                         ; 21
	JSR Clockslide_100               ; 121
	JSR Clockslide_50                ; 171
	JSR Clockslide_40                ; 211
	JSR Clockslide_16                ; 227
	LDA <Test_UnOp_CycleDelayPostDMA ; 230
	JSR Clockslide37_Plus_A          ; 267 + A  (uses zero page $00/$01 only)
	RTS                              ; 273 + A: the request is 49 - A cycles away
;;;;;;;

	; A giant list of ClockSlides!
	; "What's a clockslide?"
	; It's just a subroutine that wastes a precise amount of CPU cycles.
	; If you want to waste exactly n cycles, run JSR Clockslide_n
	; (Clockslide_14 through Clockslide_50 are defined, and most larger clockslides are a combination of JSRs to those clockslides)

Clockslide_100Minus12: ; This is very handy for the following clockslides I want to make. 100, 200, etc.
	JSR Clockslide_26 ;=32
	JSR Clockslide_50 ;=80
	RTS			      ;=100-12. Remember, JSR and RTS add 12 cycles, so to make clockslide 100, I just need to JSR somewhere with JSR Clockslide_100Minus12
;;;;;;;

Clockslide_50000:
	JSR Clockslide_10000
Clockslide_40000:
	JSR Clockslide_10000
Clockslide_30000:
	JSR Clockslide_10000
Clockslide_20000:
	JSR Clockslide_10000
Clockslide_10000:
	JSR Clockslide_1000
Clockslide_9000:
	JSR Clockslide_1000
Clockslide_8000:
	JSR Clockslide_1000
Clockslide_7000:
	JSR Clockslide_1000
Clockslide_6000:
	JSR Clockslide_1000
Clockslide_5000:
	JSR Clockslide_1000
Clockslide_4000:
	JSR Clockslide_1000
Clockslide_3000:
	JSR Clockslide_1000
Clockslide_2000:
	JSR Clockslide_1000
Clockslide_1000:
	JSR Clockslide_100
Clockslide_900:
	JSR Clockslide_100
Clockslide_800:
	JSR Clockslide_100
Clockslide_700:
	JSR Clockslide_100
Clockslide_600:
	JSR Clockslide_100
Clockslide_500:
	JSR Clockslide_100
Clockslide_400:
	JSR Clockslide_100
Clockslide_300:
	JSR Clockslide_100
Clockslide_200:
	JSR Clockslide_100
Clockslide_100:      
	JSR Clockslide_100Minus12 ; Since JSR and RTS take 12 cycles, let's stall for exactly 100-12 cycles.
	RTS
;;;;;;;

;A PAL frame has about 33248 cycles, so let's make a few around that number.
; I use these clockslides enough that it actually saves bytes to do this.
; NOTE: Don't optimize these using ClockslideFromWord.
; Some tests rely on an interrupt occurring during the clockslide and changing some registers,
; while ClockslideFromWord restores the registers at the end.
Clockslide_29750:
	JSR Clockslide_100Minus12
	JSR Clockslide_50	;150
	JSR Clockslide_600	;750
	JSR Clockslide_9000 ;9750
	JSR Clockslide_20000;29750
	RTS
;;;;;;;
; [CYCLE] DOC-BACKED: PAL frame is 33247.5 cycles; this wait uses 33248.
Clockslide_PALFrame:
	JSR Clockslide_29750 ; 29750
	JSR Clockslide_3000  ; 32750
	JSR Clockslide_400   ; 33150
	JSR Clockslide_50    ; 33200
	JSR Clockslide_18    ; 33218
	JSR Clockslide_18    ; 33236
	JSR Clockslide_12    ; 33248
	RTS                  ; 33248
;;;;;;;

; [FRAME][PALAPU] DOC-BACKED over-wait: the PAL 4-step flag is clear at
; 33254 cycles after $4017=$00, set at 33255, set again at 33256, and clear
; at 33257 (blargg's PAL-hardware-derived 07.irq_flag_timing.a). This helper
; waits 33248+50=33298, deliberately longer; it is not a claim that the IRQ
; fires at 33298. The flag remains set after 33257 until read.
Clockslide_PALFrameIRQ:
	JSR Clockslide_PALFrame
	JSR Clockslide_50
	RTS
;;;;;;;

Clockslide_4320:
	JSR ClockslideFromWord
	.word 4320-12
	RTS
;;;;;;;

Clockslide37_Plus_A:;+6
	STA <$00	; +3
	LDA #$FF	; +2
	STA <$01	; +3
	LDA #36		; +2
	SEC			; +2
	SBC <$00	; +3
	STA <$00	; +3
	JMP [$0000]	; 5 + A + 6
;;;;;;;;;;;;;;;;;

Clockslide64_Minus_A:;+6   By count this is 63 - A cycles in all (6 + 3 + 2 + 3 + 5 + the slide's 44 - A), not 64 - A.
	; Every use counts it as 63 - A or uses it in a pair with Clockslide37_Plus_A, where only the sum matters.
	STA <$00	; +3
	LDA #$FF	; +2
	STA <$01	; +3
	JMP [$0000]	; +50 - A
;;;;;;;;;;;;;;;;;

WaitForVBLSpriteZeroHit:
	JSR WaitForVBlank          ; Wait for vblank
	LDA $2002                  ; Read PPUSTATUS
	AND #$40                   ; Mask away everything except the sprite zero hit flag.
	RTS                        ; RTS, and run a BEQ or BNE afterwards.
;;;;;;;

VerifySpriteZeroHits:          ; Verify that sprite zero hits work in this emulator, and don't provide false-positives just because sprite zero is on this scanline, and parts of sprite zero overlap visible pixels.
	                           ; STEP ONE: Intentionally miss a sprite zero hit.
	JSR DisableRendering       ; Disable rendering so the following can happen even out of vblank.
	JSR ClearNametable2_With24 ; Clear nametable 2 with tile $24 (empty tiles)
	JSR ClearPage2             ; Clear Page 2 with all $FFs
	JSR SetUpSpriteZero        ; Prepare sprite zero with the following values:
	.byte $00, $C0, $03, $03   ; Single dot on scanline 4, X = 08
	JSR PrintCHR               ; Update nametable
	.word $2C00                ; And 8x8 box with a single pixel hole in it. (we're intentionally missing this sprite zero hit.)
	.byte $E1, $FF             ; This will trigger the sprite zero hit.
	JSR OAMDMAWithPage2        ; OAM DMA with page 2
	JSR WaitForVBlank          ; Wait for vblank
	JSR EnableRendering        ; Draw both the background and sprites.	
	JSR WaitForVBLSpriteZeroHit; Wait for vblank and load A with $2002.6
	BNE VerifySpriteZeroHits_F ; Fail the test if the sprite zero hit occurred.
	JSR PrintCHR               ; Update nametable
	.word $2C00                ; Single dot to overlap the sprite. (we're intentionally hitting this one)
	.byte $E2, $FF             ; This will trigger the sprite zero hit.	
	JSR OAMDMAWithPage2        ; OAM DMA with page 2
	JSR WaitForVBlank          ; Wait for vblank
	JSR EnableRendering        ; Draw both the background and sprites.	
	JSR WaitForVBLSpriteZeroHit; Wait for vblank and load A with $2002.6
	RTS                        ; and return.
;;;;;;;
VerifySpriteZeroHits_F:
	LDA #0
	RTS
;;;;;;;

FAIL_MisalignedOAMDMA:
	JMP TEST_Fail

TEST_MisalignedOAMDMA_OAM:
	.byte $07, $C0, $00, $80 

TEST_MisalignedOAMDMA:
	;;; Test 1 [Misaligned OAM DMA]: Verify sprite zero hits before running the actual test. ;;;
	JSR VerifySpriteZeroHits ; Use this subroutine to verify if sprite zero hits are working.
	BEQ FAIL_MisalignedOAMDMA; And if they aren't, fail the test.
	INC <ErrorCode
	
	;;; Test 2 [Misaligned OAM DMA]: If the primary OAM Address is non-zero when the OAM DMA occurs, then the data is offset. ;;;
	; This is an easy one.
	; Basically, if the OAM Address is non-zero when the OAM DMA occurs, then the DMA will begin at a non-zero address of OAM and loop around at some point.
	; In this test, I set the OAM Address to $80, and the data at address $280 will end up in sprite zero.

	JSR PrintCHR
	.word $2C30
	.byte $C0, $FF

	JSR ClearPage2
	LDX #3
TEST_MisalignedOAMDMA_Loop:
	LDA TEST_MisalignedOAMDMA_OAM, X
	STA $280, X
	DEX
	BPL TEST_MisalignedOAMDMA_Loop
	
	JSR ResetScroll_2C00
	JSR WaitForVBlank
	LDA #$80 
	STA $2003 ; OAM Address = $80
	
	JSR OAMDMAWithPage2 ; OAM DMA, starting at address $200, but writing to address $80 of OAM, ending at address $7F.
	
	LDA #$FF  ;
	STA $2003 ; 
	STA $2004 ; Return the OAM Address back to zero without OAM corruption.
	
	JSR ClockslideFromWord
	.word 8000
	
	LDA $2002
	AND #$40
	BEQ FAIL_MisalignedOAMDMA
	
	LDA #1
	RTS
;;;;;;;

;;; SetBRKRoutineFromWord ;;;
; Updates the operands of the JMP instruction at address $600 to be the provided .word
KEYDATA_1:
	.byte $3F, $17, $13, $13, $0F, $0F, $0B, $0B, $07, $07, $03, $03, $FF, $03, $FB, $03
	.byte $F7, $03, $F3, $03, $EF, $03, $EB, $03, $E7, $03, $E3, $03, $DF, $03, $DB, $03
	.byte $D7, $03, $D3, $03, $CF, $03, $CB, $03, $C7, $03, $C3, $03, $BF, $03, $BB, $03
	.byte $B7, $03, $B3, $03, $AF, $03, $AB, $03, $A7, $03, $A3, $03, $9F, $03, $9B, $03
	.byte $82, $7F
	.byte $82, $7D
	.byte $84, $01
	.byte $82, $7F
	.byte $82, $7D
	.byte $84, $01
	.byte $01, $03
	.byte $AF, $FE
	.byte $01, $7F
	.byte $93, $01
KEY_2004_2:
	.byte $01, $FF
	.byte $BF, $01
	.byte $03, $80, $80, $00
	.byte $83, $01
	.byte $0A, $FF, $FF, $7F, $7F, $01, $01, $20, $20, $EE, $EE
	.byte $80, LOW(KEYDATA_2), HIGH(KEYDATA_2) ; continued
	.org $FD00
CSTable:            ; This is a clockslide.
    .byte $C9       ; Jumping to this byte here will take 17 cycles to reach that JMP CSTableSync.
    .byte $C9       ; Jumping to this byte here will take 16 cycles to reach that JMP CSTableSync.
    .byte $C9       ; And jumping here will take 15 cycles, and so on.
    .byte $C9       ; The purpose is to create a way to stall for a precise number of cycles.
    .byte $C9       ; I use this to stall for exactly 0 to 15 cycles (plus 2) depending on...
    .byte $C9       ; ... the lowest nybble of the .word following a JSR to ClockslideFromWord.
    .byte $C9       ; For instance, if the .word was $1003, then the lowest nybble of 3 would...
    .byte $C9       ; ... result in this routine stalling for 3 more cycles than if the value was $1000.
    .byte $C9       ;
    .byte $C9       ;
    .byte $C9       ;
    .byte $C9       ;
    .byte $C9       ;
    .byte $C9       ; If this is executed, the $C5 is the operand. +2 cycles. (4 cycles until the JMP)
    .byte $C5       ; If this is executed, the $EA is the operand. +3 cycles. (3 cycles until the JMP)
    .byte $EA       ; NOP (no operands) +2 cycles
    JMP CSTableSync ; +3 cycles
                    ;
ClockslideFromWord: ; Delay somewhere between 256 and 65536 CPU cycles.
    STA <$FF        ; I overwrite A, X, and Y during this subroutine
    STY <$FE        ; So I store them here temporarily and read them back at the end of the routine.
    STX <$FD        ;
                    ; I cannot use CopyReturnAddressToByte0 because it can take a variable amount of cycles depending on the return address.
    TSX             ; So I need to spend a few bytes doing this without the subroutine.
                    ; Grab the return address from the stack pointer, copy it to [$0000] and increment the one in the stack by 2.
    CLC             ; CLC for the upcoming ADC
    LDA $101,X      ; Load the return address low byte
    STA <$00        ; Store it in address $0000 for an upcoming LDA (Indirect), Y
    ADC #2          ; The .word after the JSR to ClockslideFromWord takes up 2 bytes, so add 2 to the return address.
    STA $101,X      ; Overwrite the return address low byte
    LDA $102,X      ; Load the return address high byte
    STA <$01        ; Store it in address $0001 for the upcoming LDA (Indirect), Y
    ADC #0          ; Add carry to high byte in case it was set when adding 2 to the low byte.
    STA $102,X      ; And overwrite the return address high byte.
                    ;
    LDA #1          ; starting at the old return address +1, read the two bytes that followed the JSR to ClockslideFromWord.
    SEC             ; set the carry flag for the upcoming SBC. We want to make sure emulators that handle JSR incorrectly can still run this.
    SBC <IncorrectReturnAddressOffset ; Subtract the value from address $003C that was set from a test around power on.
    TAY             ; Transfer the result to Y. At this point Y should equal 1 on an accurate emulator, and 2+ on an inaccurate one.
    LDA [$0000],Y   ; a JSR to ClockslideFromWord should be followed with a 16 bit .word
    STA <$20        ; We just read the low byte of this .word, and store it at address $20.
    INY             ; Increment Y
    LDA [$0000],Y   ; And read the high byte of this .word
    STA <$21        ; Store it at address $21.
                    ; This .word we just read will be the number of CPU cycles to spend inside this subroutine.
	LDA <$00        ; Since LDA (indirect), Y can take an extra cycle if a page boundary is crossed...
	CMP #$FF        ; we need to account for that.
	BNE CSWaste1Cy  ; Branches take 2 or 3 cycles depending on if it was taken or not.
CSWaste1Cy:         ; If we took 2 extra cycles from the LDA (indirect), Y's let's fall behind two cycles.
	BNE CSWaste1Cy2 ; Waste a second cycle.
CSWaste1Cy2:        ; ^
	CMP #$FE        ; And if we need to lose only a single cycle, do it again, but once.
	BNE CSWasteOnly1; ^
CSWasteOnly1:       ;
                    ; First deal with the lowest nybble.
    LDA <$20        ; Load the Low Byte from the .word
    AND #$0F        ; Mask away the upper nybble.
    EOR #$0F        ; Flip the bits in the lower nybble
    STA <$00        ; And store this to $0000 for the upcoming JMP (indirect)
    LDA #HIGH(CSTable) ; Load the high byte for the upcoming JMP (indirect)
    STA <$01        ; And store it to $0001.
    JMP [$0000]     ; Jump to CSTable_xF through CSTable_x0 in order to waste precisely the lowest nybble from .word worth of CPU cycles.
CSTableSync:        ; The clockslide there jumps here:
                    ; Now we've wasted precisely the low nybble + some overhead. We'll resolve the overhead later.
                    ; Now we take care of nybble 1.
    LDA <$20        ; Load the low byte
    LSR A           ; And shift it over four times.
    LSR A           ;
    LSR A           ;
    LSR A           ;
    TAX             ; We're going to run a loop that wastes 16 * X CPU cycles.
    JMP CSXMid      ; Jump to the middle of the loop in case X = 0.
CSXLoop:            ;
    PHP             ; +3 (this saves bytes over using LDA <$00 to spend an odd number of cycles.)
    PLP             ; +4
    NOP             ; +2
    NOP             ; +2
CSXMid:             ;
    DEX             ; +2
    BPL CSXLoop     ; +3
                    ; = 16*X + some overhead which we will resolve later.
                    ; Now wasting the high byte of the .word worth of CPU cycles is a bit tricky.
                    ; It's worth noting that (due to all the overhead with this subroutine) there is a minimum of 256 CPU cycles we can waste here.
    LDX <$21        ; X = the high byte of the .word
    JMP CSZYLoop_Mid; Just like with nybble 1, we skip ahead in case X=0.
CSZYLoop:           ; Writing a loop to waste 249 cycles makes this routine easier to copy/paste into other projects, rather than needing an existing clockslide.
    LDY #49         ; Waste exactly 249 cycles by running this loop 26 times.
CSWaste249Cy:       ; This loop (plus the LDY #49, and following LDA <$0) takes 249 cycles.
    DEY             ; With the DEX, NOP, and BNE back into this loop, the whole thing takes 256 cycles per iteration.
    BNE CSWaste249Cy;
    LDA <$00        ;
CSZYLoop_Mid:       ;
    DEX             ; Decrement X
    NOP             ; If X is not equal to zero...
    BNE CSZYLoop    ; keep running this loop.
                    ;
                    ; Since we ran that "waste 256 cycles" loop 1 less than the .word would suggest, we would have 256 cycles missing!
                    ; That's where the overhead comes in. We actually only have 94 cycles to make up.
                    ; This can easily be wasted with another loop.
    LDX #18         ; We're pretty much just going to run a loop decrementing X until X hits zero.
CSWaste94Cy:        ;
    DEX             ; X--
    BNE CSWaste94Cy ; Loop until X = 0.
	LDA <$00        ;
    LDX <$FD        ; Now the remaining instructions restore the A, X, and Y registers.
    LDY <$FE        ; ^
    LDA <$FF        ; ^
    RTS             ; We're done here.
;;;;;;;;;;;;;;;;;;;;;

AsciiToCHR:; This table converts the ASCII values stored in the ROM to the indexes into the pattern table I made. 
	; (I omit the first 32 byte values, so when reading from this table you want to offset this by -32)
	.byte $24, $26, $24, $24, $35, $24, $24, $24, $24, $24, $32, $30, $29, $31, $25, $33
	.byte $00, $01, $02, $03, $04, $05, $06, $07, $08, $09, $28, $24, $24, $34, $24, $27
	.byte $24, $0A, $0B, $0C, $0D, $0E, $0F, $10, $11, $12, $13, $14, $15, $16, $17, $18
	.byte $19, $1A, $1B, $1C, $1D, $1E, $1F, $20, $21, $22, $23, $24, $24, $24, $24, $24
	.byte $24, $0A, $0B, $0C, $0D, $0E, $0F, $10, $11, $12, $13, $14, $15, $16, $17, $18
	.byte $19, $1A, $1B, $1C, $1D, $1E, $1F, $20, $21, $22, $23;, $24, $24, $24, $24, $24

	.org $FDF3
TEST_IFlagLatency_PageBoundaryTest:
	;;; Test B [Interrupt Flag Latency]: Do branches poll for interrupts before cycle 4? (They should) ;;;
	; Rebuilt on the frame counter IRQ (the DMC IRQ cannot be raised inside an instruction on a 2A07); see
	; TEST_IFlagLatency_TestB.
	JSR TEST_IFlagLatency_TestB
	BNE FAIL_IFlagLatencyC
	INC <ErrorCode
	JMP TEST_IFlagLatency_Test_C
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	.org $FE00
	.byte $40 ; This is the DPCM sample used for the APU Register Activation test (it has to stay at $FE00).
FAIL_IFlagLatencyC:
	SEI
	JMP TEST_Fail
;;;;;;;;;;;;;;;;;
	.org $FE0F
New_VBL_Sync:
	; Syncs to scanline 241, dot 0. [SYNC] The exact synthesis routine is still UNVERIFIED on PAL hardware.
	JSR DisableRendering
	LDA $2002
New_VBL_Sync_Loop1:
	LDA $2002
	BMI New_VBL_Sync_Loop1
	JSR ClockslideFromWord
	.word 33188
New_VBL_Sync_Loop2:
	JSR ClockslideFromWord
	.word 33241
	LDA $2002				; +4
	BPL New_VBL_Sync_Loop2	; +3 = 33248
	JSR ClockslideFromWord
	.word 33248
	JSR ClockslideFromWord
	.word 33248
	RTS
;;;;;;;

	.org $FE49	

		
;;;;;;;;;;

VerifyReturnAddressesAreCorrect:
	TSX
	INX
	LDA $100, X
	; $02 is the correct value to read here. A value of $03 is wrong. $04 is right out.
	; Anyway, subtract by 2.
	SEC
	SBC #02
	STA <IncorrectReturnAddressOffset
	RTS
;;;;;;;

; PAL frame sync helper. A advances one additional PAL frame-length loop;
; dot-level phase still requires hardware validation.
VblSync_Plus_A: ; A advances by one PAL frame-length loop (33248 CPU cycles).
	PHA
	LDA <result_VblankSync_PreTest		; Check if this sync routine will loop infinitely.
	BMI VblSync_ABORT	; If it will, just RTS without syncing. It was going to fail the test anyway with frame timing that incorrect.
	JSR WaitForVBlank
	JSR New_VBL_Sync	; Sync to VBlank dot 0
	PLA
VblSync_Plus_A_Loop:   
	JSR ClockslideFromWord
	.word 33241
	CLC						; + 2
	ADC #$FF 				; + 2
	BCS VblSync_Plus_A_Loop ; + 3 if looping, 2 otherwise. (33248 CPU cycles if looping.)
	JSR ClockslideFromWord
	.word 33248
	JSR ClockslideFromWord
	.word 33248
	JSR ClockslideFromWord
	.word 33248
	BIT $2002
	RTS
	
	VblSync_ABORT:	; This emulator failed the pre-test, implying that this will loop infinitely, so instead of doing that, just don't bother.
	PLA
	RTS
;;;;;;;

FlushPendingOAMCorruption:
	; Turning rendering off in the middle of a scanline can leave an OAM corruption pending (NESdev Errata); it
	; happens when rendering is turned on again. Render one frame, so a pending corruption happens now.
	JSR WaitForVBlank
	JSR EnableRendering
	JSR WaitForVBlank
	RTS
;;;;;;;
	; [ALE + Read] is placed here (banks 1 and 2 are full).
TEST_ALERead:
	; STATUS: DERIVED [2C07] The 2C02 test (from Damian Yerrick's boing2k7 observation): a $2007 read whose address latch
	; (ALE) falls on dot 229, together with the background fetch's, makes the low pattern plane fetch read $0FFF, so a
	; transparent nametable draws pixels 241-248 and sprite zero (X=$F4, scanline 3) hits them. The read must start on
	; dot 214 of the scanline. On PAL a read can only be placed in 1.6-dot steps, and the CPU/PPU phase of a console
	; is unknown, so the read is tried 6 times, 1.6 dots later each time (one more 33248-cycle frame of VblSync_Plus_A
	; per try), across the target dot. A PPU without the effect never hits: the nametable is all transparent.
	; ALIGNMENT: every way this ROM can move the read (whole CPU cycles, 3.2 dots; extra frames, 1.6 dots) is a
	; multiple of 1.6 dots, and 5 x 1.6 = 8, the length of a fetch group. So whether any try's address latch can fall on
	; dot 227 depends only on the console's CPU/PPU clock alignment at power-on (5 alignments 0.2 dots apart: a CPU
	; cycle is 16 master clocks, a dot 5). By the PPUDATA read timing 2 of the 5 can reach it; the measured alignment always
	; runs one of the other 3 (its tries latch on dots 220, 222, 223, 225, 226, 228), so it always fails here.
	; Error 2 therefore means: no hit after 6 tries. On a console, power-cycle and run again; if no power-on in about 10
	; ever passes, the 2C07 lacks the effect. $5F = the try that hit (0-5), or 6 if none did.
	;;; Test 1 [ALE + Read]: Verify sprite zero hits before running the actual test. ;;;
	JSR VerifySpriteZeroHits
	BNE TEST_ALERead_SZOK
	JMP TEST_Fail
TEST_ALERead_SZOK:
	INC <ErrorCode
	;;; Test 2 [ALE + Read]: Can a well-timed LDA $2007 corrupt a background's low-bit plane fetch? ;;;
	JSR DisableRendering
	JSR ClearNametable2_WithF0 ; CHR $F0 is a transparent tile from the $Fx row of CHR data.
	JSR WriteToPPUADDRWithByte ; Update palette 3 so the artifact is visible.
	.byte $3F, $0D
	.byte $21, $FF
	JSR ResetScroll_2C00
	JSR SetUpSpriteZero        ; Scanline 3, X=$F4, CHR $C0 is a single pixel in its upper left corner.
	.byte $02, $C0, $00, $F4
	LDA #0
	STA <$5F ; try
TEST_ALERead_Try:
	LDA #0
	STA $2003
	LDA #2
	STA $4014 ; OAM DMA before the sync (see Sync_ToPreRenderDot324)
	LDA <$5F
	JSR VblSync_Plus_A
	LDA #$1E
	STA $2001
	JSR ClockslideFromWord
	.word 7919 ; the 6 tries read $2007 on dots 216.6-226.2 of scanline 3 (the 2C02 version: dot 224)
	LDA $2007             ; Read from $2007 to corrupt the background read cadence.
	NOP
	NOP
	LDA $2002             ; Read from $2002 to check if a sprite zero hit occurred.
	AND #$40
	BNE TEST_ALERead_Pass
	JSR DisableRendering
	INC <$5F
	LDA <$5F
	CMP #6
	BNE TEST_ALERead_Try
	JMP FAIL_ALERead ; restores the default palette
TEST_ALERead_Pass:
	JSR DisableRendering
	JSR WaitForVBlank
	JSR SetUpDefaultPalette
	LDA #1
	RTS
;;;;;;;
	.org $FF00
Clockslide:
	; JSR takes 6 cycles.
	; The following bytes are labeled with the total cycles until the RTS instruction ends.
	; Clockslide has a minimum of 12 cycles.
	; EXAMPLE USE: Let's count CPU cycles!
	; LDA #00            ; +2 cycles
	; STA $0100          ; +4 cycles
	; JSR Clockslide_45  ; +45 cycles
	; LDA $2002			 ; +3 cycles
	
Clockslide_50:
	.byte $C9	; If you start executing here, there are 38 cycles between here and the RTS instruction. (+6 for the JSR, +6 for the RTS = 50)
Clockslide_49:
	.byte $C9	; If you start executing here, there are 37 cycles between here and the RTS instruction. (+6 for the JSR, +6 for the RTS = 49)
Clockslide_48:
	.byte $C9	; If you start executing here, there are 36 cycles between here and the RTS instruction. (+6 for the JSR, +6 for the RTS = 48)
Clockslide_47:
	.byte $C9	; ... and so on.
Clockslide_46:
	.byte $C9	; In case you're wondering how this works...
Clockslide_45:
	.byte $C9	; opcode $C9 is for "CMP Immediate". (Which unfortunately updates the CPU status flags...)
Clockslide_44:
	.byte $C9	; CMP Immediate takes 2 cycles, and is also 2 bytes long. (Opcode and Operand)
Clockslide_43:
	.byte $C9	; ...
Clockslide_42:
	.byte $C9
Clockslide_41:
	.byte $C9
Clockslide_40:
	.byte $C9
Clockslide_39:
	.byte $C9
Clockslide_38:
	.byte $C9
Clockslide_37:
	.byte $C9
Clockslide_36:
	.byte $C9
Clockslide_35:
	.byte $C9
Clockslide_34:
	.byte $C9
Clockslide_33:
	.byte $C9
Clockslide_32:
	.byte $C9
Clockslide_31:
	.byte $C9
Clockslide_30:
	.byte $C9
Clockslide_29:
	.byte $C9
Clockslide_28:
	.byte $C9
Clockslide_27:
	.byte $C9
Clockslide_26:
	.byte $C9
Clockslide_25:
	.byte $C9
Clockslide_24:
	.byte $C9
Clockslide_23:
	.byte $C9
Clockslide_22:
	.byte $C9
Clockslide_21:
	.byte $C9
Clockslide_20:
	.byte $C9
Clockslide_19:
	.byte $C9
Clockslide_18:
	.byte $C9
Clockslide_17:
	.byte $C9
Clockslide_16:
	.byte $C9	; If this is executed, the $C5 is the operand. +2 cycles.
Clockslide_15:
	.byte $C5	; CMP <ZeroPage (takes 3 cycles). If this is executed, the $EA is the operand.
Clockslide_14:
	.byte $EA	; NOP (no operands)
Clockslide_12:
	.byte $60	; RTS (+6 cycles)
;;;;;;;;;;;;;

DMASync: ; Line up the CPU and the DMA. The DMA occurs 406 CPU cycles after the RTS. (typically, this leads into a few clockslides, and another RTS)
	; PAL 2A07 note: the open-bus synchronization loop below needs the DMA's byte to show up in an open-bus DATA
	; read. On a 2A07 the DMA only halts the CPU on an opcode fetch (NESdev forum "PAL DMA behavior", t=25939), so it
	; never does: the pre-test leaves 2 and DMASyncWithoutOpenBus is used. The two paths have DIFFERENT contracts:
	; DMASync_TheGoodOne returns 374 cycles before the DMA (400 - 26); DMASyncWithoutOpenBus returns 322 cycles before
	; the point from which the next DMA lands on the first opcode fetch (see its own comments). DMASync_50CyclesRemaining
	; and DMASync_50MinusACyclesRemaining are written for the 2A07 path (322).
	LDA <result_DMCDMASync_PreTest ; Check if we need to run the "does the DMA update the data bus" test.
	BEQ TEST_DoesTheDMAUpdateOpenBus ; if we haven't ran this yet, run this test, then return back here.
	CMP #01
	BEQ DMASync_TheGoodOne
	JMP DMASyncWithoutOpenBus
DMASync_TheGoodOne:
	; This function very reliably exits with exactly one rate $F period minus 26 CPU cycles until the DMA occurs:
	; 374 on the 2A07 (400 - 26; NESdev "APU DMC" PAL rate table, $F = 50 * 8).
	; However, it relies on open bus behavior, with the consequence of an infinite loop if not correctly emulated.
	STA <Copy_A
	LDA #$4F ; loop, max speed.
	STA $4010
	LDA #0
	STA $4011 ; minimum value of DMC
	LDA #$FF
	STA $4012 ; Sample address $FFC0.
	LDA #0
	STA $4013 ; #1 * 0 + 1 = 1 byte length. (IT MUST BE A 1-BYTE LONG SAMPLE! Some tests rely on the address counter being reset when the DMA occurs.)
	LDA #$10
	STA $4015 ; Start the DMC DMA loop
	NOP
	NOP
DMASync_Loop:
	LDA $4000 ; Open bus! Either we will read $40 from the high byte, or $00 from the DMA.
	;	[Read AD] [Read 00] [Read 40] [DMA PUT (1)] [DMA GET (2)] [DMA PUT (3)] [DMA GET (4)] [Read open bus (5)]
	BNE DMASync_Loop ; If the DMA occurs, LDA $4000 will read $00 ; +2 (7)
	LDA #$0F ; don't loop, continue at max speed. ; +2 (9)
	STA $4010 ; +4 (13)
	LDA <$00  ; +3 (16)
	LDA Copy_A; +4 (20)
	RTS 	  ; +6 (26)
	; the next DMA is one rate $F period after the detected one: 400 - 26 = 374
	; on the 2A07 (the wrappers DMASync_50CyclesRemaining / _50MinusA count from 374).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
	
TEST_DoesTheDMAUpdateOpenBus:
	; let's find out!
	STA <Copy_A
	LDA $4000
	BEQ TEST_DoesTheDMA_Fail
	LDA #$4F ; loop, max speed.
	STA $4010
	LDA #0
	STA $4011 ; minimum value of DMC
	LDA #$FF
	STA $4012 ; Sample address $FFC0.
	LDA #0
	STA $4013 ; #1 byte length. (I still have 17 00s in a row since other tests do use a length of 17)
	LDA #$10
	STA $4015 ; Start the DMC DMA loop
	LDX #0
	LDY #0
TEST_DoesTheDMA_Loop:
	DEX
	BNE TEST_DoesTheDMA_LoopPostDec
	DEY
	BEQ TEST_DoesTheDMA_Fail
TEST_DoesTheDMA_LoopPostDec:
	; The loop is 14 CPU cycles (DEX 2, BNE 3, NOP 2, LDA 4, BNE 3); why not 12:
	; The open-bus value only shows the DMA's byte when the DMA halts the CPU on the LDA $4000 read cycle itself.
	; Between two DMAs at rate $F the CPU runs one period minus the DMA's 3-4 stolen cycles: 400 - 4 = 396 on the
	; 2A07 (NESdev "APU DMC" PAL rate table, "DMA"). With a 12-cycle loop, 396 = 33 * 12, so
	; on the 2A07 every DMA lands on the same cycle of the loop (only the DEY path every 256 passes moves it, by 3):
	; 8 of the 12 cycles are never reached, and if the read cycle is one of them the pre-test reports 2 whatever the
	; hardware does. 396 mod 14 = 4 and the DEY path moves by 3, so every cycle of a 14-cycle loop is reached.
	NOP
	LDA $4000
	BNE TEST_DoesTheDMA_Loop
	LDA $4000
	BEQ TEST_DoesTheDMA_Fail
	LDA #01
	.byte $2C ; BIT absolute, which swallows the next 2-byte LDA #02 so both paths share one STA / JMP. This keeps the
	; routine clear of the .org $FFA0 below; separate paths do not fit and the last byte of a JMP would be overwritten.
TEST_DoesTheDMA_Fail:
	; 2 = no usable open-bus DMA sync on this CPU: the DMA never showed up in an open-bus read. DMASync then
	; uses DMASyncWithoutOpenBus.
	LDA #02
	STA <result_DMCDMASync_PreTest
	JMP DMASync
;;;;;;;;;;;;;;;	

	.org $FFA0
PressStartToContinue:
	JSR ReadController1
	LDA <controller_New
	AND #$10
	BEQ PressStartToContinue_End
	JSR SetUpDefaultPalette
	JSR DisableNMI
	JSR DisableRendering
	JSR ClearNametable
	LDX #$EF ; Due to some tests modifying the stack pointer, it's convenient to put it at EF instead of FF.
	TXS		 ; This prevents some tests where the resulting stack pointer is 00 from pushing data, and overwriting the bottom of the stack.
	JMP ReloadMainMenu
PressStartToContinue_End:
	RTI
;;;;;;;
	
	.org $FFC0
	; 33 00s. This will be the DPCM "audio sample" played during the DMC DMA Sync loop. It should just be silence.
	.byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
	.byte $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00
	
	OAMDMAWithPage2:
	LDA #2
	STA $4014
	RTS
;;;;;;;
	
	.org $FFF5
TEST_AddrMode_Relative_FFF5:
	; This is part of test 2 of TEST_AddrMode_Relative
	; A = 0, so this branch to $0050 is always taken.
	LDA #0
	.byte $F0, $57; BEQ to address $0050
	; Address $0050 contains bytes that will branch back here to this RTS.
	RTS
;;;;;;;
	.org $FFFA	; Interrupt vectors go here:
	.word $0700 ; NMI
	.word RESET ; Reset
	.word $0600 ; IRQ

	;;;; NESASM COMPILER STUFF, ADDING THE PATTERN DATA ;;;;

	.incchr "Sprites.pcx"
	.incchr "Tiles.pcx"