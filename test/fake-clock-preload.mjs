let fakeNow = 1_000_000;
Date.now = () => fakeNow++;
