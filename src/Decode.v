From HTTP2 Require Import
     Equiv
     Types.
From HTTP2.Util Require Import
     BitVector
     Parser
     VectorUtil
     StringUtil.
From Coq Require Import
     Bvector
     ByteVector
     NArith
     Ndigits
     Vector.
From ExtLib Require Import Functor Monad MonadExc.
Import FunctorNotation MonadNotations.
Import IMonadNotations.

From Coq Require Vector.
Import Vector.VectorNotations.

Open Scope bool_scope.
Open Scope N_scope.
Open Scope monad_scope.

Program Definition get31bit {m : nat -> Tycon}
        `{IMonad_nat m} `{MParser byte (m 1%nat)} :
  m 4%nat (bit * Bvector 31)%type :=
  icast (
    b <-(to_Bvector) iget_vec 4;;
    let '(e, sid) := uncons b in
    iret (e, sid))%imonad.

Program Definition decode31bit {m : nat -> Tycon}
           `{IMonad_nat m} `{MParser byte (m 1%nat)} :
  m 4%nat (bit * N)%type :=
  icast (
    '(e, sid) <- get31bit;;
    iret (e, Bv2N 31 sid))%imonad.

Program Definition decodeStreamId {m : nat -> Tycon}
        `{IMonad_nat m} `{MParser byte (m 1%nat)} :
    m 4%nat (bit * StreamId)%type :=
  icast (
      b <-(to_Bvector) iget_vec 4;;
      let '(e, sid) := uncons b in
      iret (e, sid))%imonad.

Program Definition decodeFrameHeader {m : nat -> Tycon}
        `{IMonad_nat m} `{MParser byte (m 1%nat)} :
  m 9%nat (FrameType * FrameHeader)%type :=
  icast (
    let fromFrameTypeId' x := fromFrameTypeId (ByteV2N x) in
    length         <-(ByteV2N)        iget_vec 3;;
    frameType      <-(fromFrameTypeId')       iget_vec 1;;
    flags          <-(to_Bvector)  iget_vec 1;;
    '(_, streamId) <- decodeStreamId;;              (* 4 *)
    iret (frameType, {| payloadLength := length;
                        flags         := flags;
                        streamId      := streamId |}))%imonad.

Program Definition checkFrameHeader {m : Tycon}
        `{Monad m} `{MonadExc HTTP2Error m}
        (settings : Settings) (typfrm : FrameType * FrameHeader) :
  m unit :=
  let (typ, header) := typfrm in
  let length := payloadLength header in
  let fff    := flags         header in
  let id     := streamId      header in
  assert (payloadLength header <=? Bv2N 32 (settings SettingMaxFrameSize))
         (ConnectionError FrameSizeError
                          "exceeds maximum frame size");;
  assert (negb (nonZeroFrameType typ && isControl id))
         (ConnectionError ProtocolError
                          "cannot used in control stream");;
  assert (negb (zeroFrameType typ && negb (isControl id)))
         (ConnectionError ProtocolError
                          "cannot used in non-zero stream");;
  let checkPadded :=
      assert (negb (testPadded fff && (length <? 1)))
             (ConnectionError
                FrameSizeError
                "insufficient payload for Pad Length") in
  match typ with
  | DataType => checkPadded
  | HeadersType =>
    checkPadded;;
    when (testPriority fff) (
      assert (5 <=? length)
             (ConnectionError
                FrameSizeError
                "insufficient payload for priority fields");;
      when (testPadded fff) (
        assert (6 <=? length)
               (ConnectionError
                  FrameSizeError
                  "insufficient payload for Pad Length and priority fields")
      )
    )
  | PriorityType =>
    assert (5 =? length)
           (StreamError FrameSizeError id)
  | RSTStreamType =>
    assert (4 =? length)
           (ConnectionError
              FrameSizeError
              "payload length is not 4 in rst stream frame")
  | SettingsType =>
    assert (0 =? length mod 6)
           (ConnectionError
              FrameSizeError
              "payload length is not multiple of 6 in settings frame");;
    when (testAck fff) (
      assert (0 =? length)
             (ConnectionError FrameSizeError
                              "payload length must be 0 if ack flag is set")
    )
  | PushPromiseType =>
    (* checkme: https://hackage.haskell.org/package/http2-1.6.3/docs/src/Network-HTTP2-Decode.html#line-102 *)
    assert (negb (0 =? Bv2N 32 (settings SettingEnablePush)))
           (ConnectionError ProtocolError "push not enabled");;
    assert (isResponse id)
           (ConnectionError
              ProtocolError
              "push promise must be used with even stream identifier");;
    checkPadded
  | PingType =>
    assert (8 =? length)
           (ConnectionError
              FrameSizeError
              "payload length must be 8 bytes in ping frame")
  | GoAwayType =>
    assert (8 <=? length)
           (ConnectionError
              FrameSizeError
              "goaway body must be 8 bytes or larger")
  | WindowUpdateType =>
    assert (4 =? length)
           (ConnectionError
              FrameSizeError
              "payload length must be 4 bytes in window update frame")
  | _ => ret tt
  end.

Solve All Obligations with repeat constructor; intro; discriminate.

(* Section 6.1:
     "If the length of the padding is the length of the frame payload
     or greater, the recipient MUST treat this as a connection error
     (Section 5.4.1) of type PROTOCOL_ERROR." *)
Definition decodeWithPadding {m : Tycon} {A : Type}
           `{Monad m} `{MonadExc HTTP2Error m} `{MParser byte m}
           (decode : N -> m (Padding -> A))
           (h : FrameHeader) (len : N) :
  m A%type :=
  let fff := flags h in
  if testPadded fff then (
    padlen <-(N_of_ascii) get_byte;;
    assert (padlen <=? len)
           (ConnectionError ProtocolError "too much padding");;
    bs <- decode (len - padlen - 1);;
    pad <- get_bytes (N.to_nat padlen);; (* Discard padding *)
    ret (bs pad)
  )%monad else (
    bs <- decode len;;
    ret (bs "")).

Close Scope nat_scope.

Definition FramePayloadDecoder (frameType : FrameType) :=
  forall m `{Monad m} `{MonadExc HTTP2Error m} `{MParser byte m},
    FrameHeader -> N -> m (FramePayload frameType).

Definition decodeDataFrame : FramePayloadDecoder DataType :=
  fun _ _ _ _ =>
    decodeWithPadding (fun n =>
      DataFrame <$> get_bytes (N.to_nat n)).

Program Definition priority {m : nat -> Tycon}
        `{IMonad_nat m} `{MParser byte (m 1%nat)} :
  m 5%nat Priority :=
  icast (
    (* Split a 32-bit field into 1+31. *)
    '(e, id) <- decodeStreamId;;
    w <- get_byte;;
    let weight := to_Bvector [w] in
    iret {| exclusive := e;
            streamDependency := id;
            weight := weight |}
  )%imonad.

Definition decodeHeadersFrame :
  FramePayloadDecoder HeadersType :=
  fun _ _ _ _ h =>
    decodeWithPadding (fun n =>
      let fff := flags h in
      if testPriority fff
      then
        p <- unindex priority;;
        s <- get_bytes (N.to_nat (n - 5));;
        ret (HeadersFrame (Some p) s)
      else
        s <- get_bytes (N.to_nat n);;
        ret (HeadersFrame None s)) h.

Definition decodePriorityFrame :
  FramePayloadDecoder PriorityType :=
  fun _ _ _ _ _h _n =>
    (* n must be 5 *)
    p <- unindex priority;;
    ret (PriorityFrame p).

Definition decodeRSTStreamFrame :
  FramePayloadDecoder RSTStreamType :=
  fun _ _ _ _ _n _h =>
    (* n must be 4 *)
    ecode <-(ByteV2N) get_vec 4;;
    ret (RSTStreamFrame (fromErrorCodeId ecode)).

Definition decodeSetting {m : Tycon} `{Monad m} `{MParser byte m} :
  m Setting :=
  id  <-(to_Bvector) get_vec 2;;
  val <-(to_Bvector) get_vec 4;;
  ret (id, val).

Definition decodeSettingsFrame :
  FramePayloadDecoder SettingsType :=
  fun _ _ _ _ _h n =>
    (* n must be a multiple of 6 *)
    let n := N.div n 6%N in
    ss <- N.iter n (fun more =>
                      s <- decodeSetting;;
                      ss <- more;;
                      ret (s :: ss)%list)
                   (ret List.nil);;
    ret (SettingsFrame ss).

Definition decodePushPromiseFrame :
  FramePayloadDecoder PushPromiseType :=
  fun _ _ _ _ =>
    decodeWithPadding (fun n =>
      (* n must be at least 4 *)
      id <-(snd) unindex decodeStreamId;;
      bs <- get_bytes (N.to_nat (n-4));;
      ret (PushPromiseFrame id bs)).

Definition decodePingFrame :
  FramePayloadDecoder PingType :=
  fun _ _ _ _ _h _n =>
    (* n must be 8 *)
    v <- get_vec 8;;
    ret (PingFrame v).

Definition decodeGoAwayFrame :
  FramePayloadDecoder GoAwayType :=
  fun _ _ _ _ h n =>
    (* n must be at least 8 *)
    id <-(snd) unindex decodeStreamId;;
    ecode <-(ByteV2N) get_vec 4;;
    debug <- get_bytes (N.to_nat (n - 8));;
    ret (GoAwayFrame id (fromErrorCodeId ecode) debug).

Definition decodeWindowUpdateFrame :
  FramePayloadDecoder WindowUpdateType :=
  fun _ _ _ _ _h _n =>
    (* n must be 4 *)
    inc <-(snd) unindex get31bit;;
    ret (WindowUpdateFrame inc).

Definition decodeContinuationFrame :
  FramePayloadDecoder ContinuationType :=
  fun _ _ _ _ _h n =>
    hbf <- get_bytes (N.to_nat n);;
    ret (ContinuationFrame hbf).

Definition decodeUnknownFrame ty :
  FramePayloadDecoder (UnknownType ty) :=
  fun _ _ _ _ _h n =>
    bs <- get_bytes (N.to_nat n);;
    ret (UnknownFrame ty bs).

Definition decodeFrame {m : Tycon}
           `{Monad m} `{MonadExc HTTP2Error m} `{MParser byte m}
           (settings : Settings) :
           m Frame :=
  '((ftype, fheader) as fth) <- unindex decodeFrameHeader;;
  checkFrameHeader settings fth;;
  let decodeFrame' : FramePayloadDecoder ftype :=
      match ftype with
      | DataType => decodeDataFrame
      | HeadersType => decodeHeadersFrame
      | PriorityType => decodePriorityFrame
      | RSTStreamType => decodeRSTStreamFrame
      | SettingsType => decodeSettingsFrame
      | PushPromiseType => decodePushPromiseFrame
      | PingType => decodePingFrame
      | GoAwayType => decodeGoAwayFrame
      | WindowUpdateType => decodeWindowUpdateFrame
      | ContinuationType => decodeContinuationFrame
      | UnknownType _ => decodeUnknownFrame _
      end
  in
  fpayload <- decodeFrame' _ _ _ _ fheader (payloadLength fheader);;
  ret {|
    frameHeader := fheader;
    frameType := ftype;
    framePayload := fpayload;
  |}.
