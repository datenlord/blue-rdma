import DataTypes :: *;

interface Controller;
    method Bool isRTS();
    method Bool isRTRorRTS();

    method Bool getRetryPulse();
    method Action setRetryPulse();

    method PendingReqCnt getPendingReqNumLimit();
    method Action setPendingReqNumList(PendingReqCnt cnt);
    // method PendingReqCnt getPendingReadAtomicReqnumList();

    method PMTU getPMTU();
    method Action setPMTU(PMTU pmtu);
    method PSN getNPSN();
    method Action setNPSN(PSN psn);
    method PSN getEPSN();
    method Action setEPSN(PSN psn);
endinterface

module mkController(Controller);
    // TODO: initialize controller
    Reg#(Bool) initializedReg <- mkReg(False);

    Reg#(QpState) stateReg <- mkReg(RESET);

    Reg#(Bool) retryPulseReg <- mkReg(False);

    Reg#(QPN) sqpnReg <- mkRegU;
    Reg#(QPN) dqpnReg <- mkRegU;

    Reg#(PendingReqCnt) pendingReqNumLimitReg <- mkRegU;
    // Reg#(PendingReqCnt) pendingReadAtomicReqNumList <- mkRegU;

    Reg#(PMTU) pmtuReg <- mkRegU;
    Reg#(PSN)  npsnReg <- mkRegU;
    Reg#(PSN)  epsnReg <- mkRegU;

    rule clearRetryPulse if (retryPulseReg);
        retryPulseReg <= False;
    endrule

    method Bool isRTS() = stateReg == RTS;
    method Bool isRTRorRTS() = stateReg == RTR || stateReg == RTS;

    method Bool getRetryPulse() = retryPulseReg;
    method Action setRetryPulse() if (!retryPulseReg);
        retryPulseReg <= True;
    endmethod

    method PSN getSQPN() if (initializedReg) = sqpnReg;
    method Action setSQPN(PSN sqpn);
        sqpnReg <= sqpn;
    endmethod
    method PSN getDQPN() if (initializedReg) = dqpnReg;
    method Action setDQPN(PSN dqpn);
        dqpnReg <= dqpn;
    endmethod
    
    method PendingReqCnt getPendingReqNumLimit() if (initializedReg) = pendingReqNumLimitReg;
    method Action setPendingReqNumList(PendingReqCnt cnt);
        pendingReqNumLimitReg <= cnt;
    endmethod

    method PMTU getPMTU() if (initializedReg) = pmtuReg;
    method Action setPMTU(PMTU pmtu);
        pmtuReg <= pmtu;
    endmethod
    method PSN getNPSN() if (initializedReg) = npsnReg;
    method Action setNPSN(PSN psn);
        npsnReg <= psn;
    endmethod
    method PSN getEPSN() if (initializedReg) = epsnReg;
    method Action setEPSN(PSN psn);
        epsnReg <= psn;
    endmethod
endmodule