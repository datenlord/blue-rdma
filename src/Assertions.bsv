function Action dynAssert(Bool b, String assertName, Fmt assertFmtMsg);
    action

    let pos = printPosition(getStringPosition(assertName));
    if (!b) begin
        $fatal(2, "DynAssert failed in %m @time=%0d, %s-- %s: ", $time, pos, assertName, assertFmtMsg);
    end

    endaction
endfunction

function Action staticReport(String assertName, Fmt assertFmtMsg);
    action

    let pos = printPosition(getStringPosition(assertName));
    $fatal(2, "StaticReport @ time=%0d, %s-- %s: ", $time, pos, assertName, assertFmtMsg);

    endaction
endfunction

/*
package Assertions(staticAssert, dynamicAssert, dynAssert, continuousAssert) where

primitive primGetEvalPosition :: a -> Position__
primitive primGetNamePosition :: Name__ -> Position__

assertMessage :: String -> String -> String
assertMessage which mess =
  letseq pos = getStringPosition mess -- get position of original message literal
  in (which +++" assertion failed: " +++ printPosition pos +++ mess)

--@ \subsubsection{Assert}
--@
--@ \index{Assert@\te{Assert} (package)|textbf}
--@ The \te{Assert} package contains definitions to test assertions
--@ in the code.
--@

empty :: Empty
empty = interface Empty

--@ \index{staticAssert@\te{staticAssert}|textbf}
--@ Compile time assertion.  Can be used anywhere a compile-time statement is valid.
--@ \begin{libverbatim}
--@ function Module#(Void) staticAssert(Bool b, String s);
--@ \end{libverbatim}
staticAssert :: (IsModule m c) => Bool -> String -> m (Empty)
staticAssert b s = if not testAssert || b then
                      return empty
                   else primError (getStringPosition s) ("Static assertion failed: " +++ s)

--@ \index{dynamicAssert@\te{dynamicAssert}|textbf}
--@ Run time assertion.  Can be used anywhere an Action is valid, and is
--@ tested whenever it is executed.
--@ \begin{libverbatim}
--@ function Action dynamicAssert(Bool b, String s);
--@ \end{libverbatim}
dynamicAssert :: Bool -> String -> Action
dynamicAssert = if not testAssert then (\ _ _ -> noAction)
                else (\ b s -> if b then noAction else
                        action
                          $display (assertMessage "Dynamic" s)
                          $finish 1
                     )

assertPosition :: String -> a -> String
assertPosition which a =
  letseq pos = primGetEvalPosition a
  in (which +++" assertion failed: " +++ printPosition pos +++ ", ")

dynAssert :: Bool -> String -> Fmt -> Action
dynAssert = if not testAssert then (\ _ _ _ -> noAction)
                else (\ b s fmt -> if b then noAction else
                        action
                          $display (assertPosition "Dynamic" s +++ fmt)
                          $finish 1
                     )

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