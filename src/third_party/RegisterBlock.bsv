
import FIFOF :: *;
import Connectable :: *;
import GetPut :: *;
import Vector :: *;
import Ringbuf :: *;
import ClientServer :: *;

import PrimUtils :: *;
import UserLogicTypes :: *;
import UserLogicSettings :: *;


/*

CSR space layout

The CSR address space is split into 4kB groups, each group has 1k 4B CSR;

Group Idx     Desc
=========     ================
0x000         C2H Queue 0
0x001         C2H Queue 1

0x008         H2C Queue 0
0x009         H2C Queue 1

0x020         Hardware Const Block (Read Only)
0x021         Hardware Global Control Block
*/


typedef enum {
    CsrGroupIdxC2hQueue0                = 'h000,
    CsrGroupIdxC2hQueue1                = 'h001,
    CsrGroupIdxH2cQueue0                = 'h008,
    CsrGroupIdxH2cQueue1                = 'h009,
    CsrGroupIdxHardwareConsts           = 'h020,
    CsrGroupIdxHardwareGlobalControl    = 'h021,
    CsrGroupIdxMaxGuard                 = 'h0FF
} CsrGroupIndex deriving(Bits, Eq, FShow);

typedef struct {
     Bit#(CSR_GROUP_CNT_WIDTH)     groupIndex;
     Bit#(CSR_GROUP_WIDTH)         groupOffset;
     Bit#(CSR_ADDR_INTERVAL_WIDTH) reservedLSB;
} CsrAddrRawLayout deriving (Bits, Eq, FShow);

typedef enum {
    CsrGroupOffsetForRingbufBaseAddrLow = 'h0,
    CsrGroupOffsetForRingbufBaseAddrHigh = 'h1,
    CsrGroupOffsetForRingbufHeadPointer = 'h2,
    CsrGroupOffsetForRingbufTailPointer = 'h3,
    CsrGroupOffsetForRingbufMaxGuard = 'h3FF
} CsrGroupOffsetForRingbuf deriving(Bits, Eq, FShow);

typedef enum {
    CsrGroupOffsetForHardwareConstHwVersion = 'h0,
    CsrGroupOffsetForHardwareConstMaxGuard = 'h3FF
} CsrGroupOffsetForHardwareConst deriving(Bits, Eq, FShow);

typedef enum {
    CsrGroupOffsetForHardwareGlobalControlSoftReset = 'h0,
    CsrGroupOffsetForHardwareGlobalControlMaxGuard = 'h3FF
} CsrGroupOffsetForHardwareGlobalControl deriving(Bits, Eq, FShow);

typedef struct {
    Bool isH2c;
    UInt#(RINGBUF_NUMBER_WIDTH) queueIndex;
    CsrGroupOffsetForRingbuf regIndex;
} CsrRingbufRegsAddress deriving (Bits, Eq, FShow);


interface RegisterBlock#(type t_addr, type t_data);
    interface Server#(CsrWriteRequest#(t_addr, t_data), CsrWriteResponse) csrWriteSrv;
    interface Server#(CsrReadRequest#(t_addr), CsrReadResponse#(t_data)) csrReadSrv;
    method Bool csrSoftResetSignal;
endinterface


module mkRegisterBlock(
    Vector#(h2cCount, RingbufH2cMetadata) h2cMetas, 
    Vector#(c2hCount, RingbufC2hMetadata) c2hMetas,
    RegisterBlock#(CsrAddr, CsrData) ifc
);
    FIFOF#(CsrWriteRequest#(CsrAddr, CsrData)) writeReqQ <- mkFIFOF;
    FIFOF#(CsrWriteResponse) writeRespQ <- mkFIFOF;
    FIFOF#(CsrReadRequest#(CsrAddr)) readReqQ <- mkFIFOF;
    FIFOF#(CsrReadResponse#(CsrData)) readRespQ <- mkFIFOF;


    Reg#(Bool) softResetSignalReg <- mkReg(False);

    rule ruleHandleWrite;
        CsrAddrRawLayout addrRaw = unpack(truncate(writeReqQ.first.addr));
        let data = writeReqQ.first.data;
        writeReqQ.deq;

        case (unpack(addrRaw.groupIndex))
            CsrGroupIdxC2hQueue0,
            CsrGroupIdxC2hQueue1,
            CsrGroupIdxH2cQueue0,
            CsrGroupIdxH2cQueue1: begin
                CsrRingbufRegsAddress regAddr = unpack(truncate(pack(writeReqQ.first.addr)>>2));
                case (regAddr.regIndex)
                    CsrGroupOffsetForRingbufBaseAddrLow: begin
                        immAssertAddressAlign(data, AddressAlignAssertionMask4KB, "Ringbuf Buffer Address CSR Write");
                        if (regAddr.isH2c) begin
                            h2cMetas[regAddr.queueIndex].addr[31:0] <= unpack(data);
                        end 
                        else begin
                            c2hMetas[regAddr.queueIndex].addr[31:0] <= unpack(data);
                        end
                    end
                    CsrGroupOffsetForRingbufBaseAddrHigh: begin
                        if (regAddr.isH2c) begin
                            h2cMetas[regAddr.queueIndex].addr[63:32] <= unpack(data);
                        end 
                        else begin
                            c2hMetas[regAddr.queueIndex].addr[63:32] <= unpack(data);
                        end
                    end 
                    CsrGroupOffsetForRingbufHeadPointer: begin
                        if (regAddr.isH2c) begin
                            h2cMetas[regAddr.queueIndex].head <= unpack(truncate(data));
                        end 
                        else begin
                            c2hMetas[regAddr.queueIndex].head <= unpack(truncate(data));
                        end
                    end
                    CsrGroupOffsetForRingbufTailPointer: begin
                        if (regAddr.isH2c) begin
                            h2cMetas[regAddr.queueIndex].tail <= unpack(truncate(data));
                        end 
                        else begin
                            c2hMetas[regAddr.queueIndex].tail <= unpack(truncate(data));
                        end
                    end
                    default: begin 
                        $display("CSR write unknown addr: %x", writeReqQ.first.addr);
                        $finish;
                    end
                endcase
            end
            CsrGroupIdxHardwareGlobalControl: begin
                case (unpack(addrRaw.groupOffset)) matches
                    CsrGroupOffsetForHardwareGlobalControlSoftReset: begin
                        softResetSignalReg <= True;
                    end
                    default: begin 
                        $display("CSR write unknown addr: %x", writeReqQ.first.addr);
                        $finish;
                    end
                endcase
            end
            default: begin 
                $display("CSR write unknown addr: %x", writeReqQ.first.addr);
                $finish;
            end
        endcase

        

        writeRespQ.enq(CsrWriteResponse{flag: 0});
    endrule

    rule ruleHandleRead;
        CsrAddrRawLayout addrRaw = unpack(truncate(readReqQ.first.addr));
        CsrRingbufRegsAddress regAddr = unpack(truncate(pack(readReqQ.first.addr)>>2));
        readReqQ.deq;
        CsrData retData = ?;
        case (unpack(addrRaw.groupIndex))
            CsrGroupIdxC2hQueue0,
            CsrGroupIdxC2hQueue1,
            CsrGroupIdxH2cQueue0,
            CsrGroupIdxH2cQueue1: begin
                case (regAddr.regIndex)
                    CsrGroupOffsetForRingbufBaseAddrLow: begin
                        if (regAddr.isH2c) begin
                            retData = zeroExtend(pack(h2cMetas[regAddr.queueIndex].addr[31:0]));
                        end 
                        else begin
                            retData = zeroExtend(pack(c2hMetas[regAddr.queueIndex].addr[31:0]));
                        end
                    end
                    CsrGroupOffsetForRingbufBaseAddrHigh: begin
                        if (regAddr.isH2c) begin
                            retData = zeroExtend(pack(h2cMetas[regAddr.queueIndex].addr[63:32]));
                        end 
                        else begin
                            retData = zeroExtend(pack(c2hMetas[regAddr.queueIndex].addr[63:32]));
                        end
                    end 
                    CsrGroupOffsetForRingbufHeadPointer: begin
                        if (regAddr.isH2c) begin
                            retData = zeroExtend(pack(h2cMetas[regAddr.queueIndex].head));
                        end 
                        else begin
                            retData = zeroExtend(pack(c2hMetas[regAddr.queueIndex].head));
                        end
                    end
                    CsrGroupOffsetForRingbufTailPointer: begin
                        if (regAddr.isH2c) begin
                            retData = zeroExtend(pack(h2cMetas[regAddr.queueIndex].tail));
                        end 
                        else begin
                            retData = zeroExtend(pack(c2hMetas[regAddr.queueIndex].tail));
                        end
                    end
                    default: begin 
                        $display("CSR read unknown addr: %x", readReqQ.first.addr);
                        $finish;
                    end
                endcase
            end
            CsrGroupIdxHardwareConsts: begin
                case (unpack(addrRaw.groupOffset)) matches
                    CsrGroupOffsetForHardwareConstHwVersion: begin
                        retData = fromInteger(valueOf(HARDWARE_VERSION));
                    end
                    default: begin 
                        $display("CSR read unknown addr: %x", readReqQ.first.addr);
                        $finish;
                    end
                endcase
            end
            default: begin 
                $display("CSR read unknown addr: %x", readReqQ.first.addr);
                $finish;
            end
        endcase
        readRespQ.enq(CsrReadResponse{data: retData});
    endrule

    interface csrWriteSrv = toGPServer(writeReqQ, writeRespQ);
    interface csrReadSrv = toGPServer(readReqQ, readRespQ);
    method csrSoftResetSignal = softResetSignalReg;
endmodule