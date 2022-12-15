function Action dynAssert(Bool condition, String assertName, Fmt assertFmtMsg);
    action
        let pos = printPosition(getStringPosition(assertName));
        if (!condition) begin
            $display(
              "DynAssert failed in %m @time=%0d: %s-- %s: ",
              $time, pos, assertName, assertFmtMsg
            );
            $finish(1);
        end
    endaction
endfunction

// function anytype staticReport(String reportMsg);
//     return message(reportMsg, ?);
//     // let pos = getStringPosition(reportMsg);
//     // return primMessage(pos, "StaticReport: " + reportMsg, ?);
// endfunction

/*
nullModule :: (IsModule m c) => m Empty
nullModule =
  module
    interface

--@ \index{continuousAssert@\te{continuousAssert}|textbf}
--@ Continuous run-time assertion (expected to be True on each clock).
--@ Can be used anywhere a module instantiation is valid.
--@ \begin{libverbatim}
--@ function Action continuousAssert(Bool b);
--@ \end{libverbatim}
continuousAssert :: (IsModule m c) => Bool -> String -> m Empty
continuousAssert = if not testAssert then (\_ _ -> nullModule)
                else (\ b s -> addRules $
                        rules
                         {-# ASSERT no implicit conditions #-}
                         {-# ASSERT fire when enabled #-}
                         "continuousAssert":
                          when not b ==>
                           action
                            $display (assertMessage "Continuous" s)
                            $finish 1
                     )
*/