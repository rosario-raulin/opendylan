module:    dylan-user
Synopsis:  The library definition for the PENTIUM-WIN32-RTG library
Author:    Tony Mann
Copyright:    Original Code is Copyright (c) 1995-2004 Functional Objects, Inc.
              All rights reserved.
License:      See License.txt in this distribution for details.
Warranty:     Distributed WITHOUT WARRANTY OF ANY KIND


define library pentium-win32-rtg
  use common-dylan;
  use io;
  use system;
  use dfmc-back-end-protocol;
  use harp;
  use pentium-harp;
  use pentium-rtg;

  export pentium-win32-rtg;
end library;
