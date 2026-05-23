{ ===========================================================================
  PolarPolygonWriteTest.pas

  ONE-SHOT focused test of Poly.Segments[i] := seg.

  Read API is verified ([[feedback-altium-polygon-api-ad26]]). The only
  unverified piece blocking the polygon-mover is whether the indexed
  setter works. This test is safe-by-design: reads segment 0 of the
  FIRST polygon found, writes the exact same value back, reports
  result. Board is not modified if the round-trip is a true no-op.

  Wrapped in PCBServer.PreProcess/PostProcess (verified pattern,
  PolarChannelArray.pas:1838, :1880). NOT using BeginModify.

  Output: C:\Users\Public\PolarPolygonWriteTest.txt

  Delete this .pas after use -- it has no purpose post-verification.
=========================================================================== }

procedure RunPolygonWriteTest;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Prim  : IPCB_Primitive;
  Poly  : IPCB_Polygon;
  seg   : TPolySegment;
  Lines : TStringList;
  outFile : String;
  writeOK : Boolean;
  errMsg  : String;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  Lines := TStringList.Create;
  Lines.Add('=== Polar Polygon Write Test ===');
  Lines.Add('Generated : ' + DateTimeToStr(Now));
  Lines.Add('Board     : ' + Board.FileName);
  Lines.Add('');
  Lines.Add('Tests Poly.Segments[i] := seg on the first polygon found.');
  Lines.Add('Reads segment 0, writes the same value back. If the assignment');
  Lines.Add('shape is valid AND writable, this is a no-op.');
  Lines.Add('');

  writeOK := False;
  errMsg := '';

  PCBServer.PreProcess;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(ePolyObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  if (Prim <> Nil) and (Prim.ObjectId = ePolyObject) then
  begin
    Poly := Prim;
    Lines.Add('Found polygon: layer=' + IntToStr(Poly.Layer) +
              '  PointCount=' + IntToStr(Poly.PointCount));

    try
      seg := Poly.Segments[0];
      Lines.Add('Read S[0]: Kind=' + IntToStr(seg.Kind) +
                '  vx=' + FloatToStrF(CoordToMMs(seg.vx), ffFixed, 12, 4) +
                '  vy=' + FloatToStrF(CoordToMMs(seg.vy), ffFixed, 12, 4));
    except
      errMsg := 'READ FAILED at runtime';
    end;

    if errMsg = '' then
    begin
      try
        { THE TEST: assignment back. If this compiles + runs, the
          indexed setter shape works. }
        Poly.Segments[0] := seg;
        writeOK := True;
      except
        errMsg := 'WRITE FAILED at runtime';
      end;
    end;
  end
  else
    errMsg := 'No polygon found on the board';

  Board.BoardIterator_Destroy(Iter);
  PCBServer.PostProcess;

  Lines.Add('');
  if writeOK then
  begin
    Lines.Add('RESULT: WRITE OK');
    Lines.Add('  Poly.Segments[i] := seg works on AD26.');
    Lines.Add('  Polygon-mover can be built with this API.');
  end
  else
  begin
    Lines.Add('RESULT: FAILED');
    Lines.Add('  Reason: ' + errMsg);
    if errMsg = 'WRITE FAILED at runtime' then
    begin
      Lines.Add('  -> Indexer exists but is read-only or rejects the value.');
      Lines.Add('     Next try: SetState_Segments(0, seg) or BeginModify wrap.');
    end;
  end;

  outFile := 'C:\Users\Public\PolarPolygonWriteTest.txt';
  Lines.SaveToFile(outFile);
  Lines.Free;

  if writeOK then
    ShowMessage('Write test: OK. Board should be unchanged.')
  else
    ShowMessage('Write test FAILED. See ' + outFile);
end;

begin
  RunPolygonWriteTest;
end.
