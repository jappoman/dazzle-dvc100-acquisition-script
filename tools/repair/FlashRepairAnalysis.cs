using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

// Conservative detector for short returns to an earlier image, followed by
// continuation of the interrupted scene. This is not a general scene-cut filter.
public static class FlashRepairAnalysis
{
    const int Width = 64, Height = 48, Size = Width * Height;
    public sealed class Episode
    {
        public int First, Last, Lag;
        public double Entry, Exit, Bridge, Match;
    }
    static double Distance(byte[] data, int a, int b)
    {
        long sum = 0;
        for (int y = 3; y < Height - 3; y++)
            for (int x = 3; x < Width - 3; x++)
                sum += Math.Abs((int)data[a * Size + y * Width + x] - data[b * Size + y * Width + x]);
        return sum / (double)((Height - 6) * (Width - 6));
    }
    public static List<Episode> Detect(byte[] data, double fps)
    {
        return Detect(data, fps, 1.10);
    }
    public static List<Episode> Detect(byte[] data, double fps, double bridgeRatio)
    {
        if (data.Length % Size != 0) throw new InvalidDataException("Partial analysis frame");
        int count = data.Length / Size;
        int minLag = Math.Max(3, (int)(fps * .16)), maxLag = (int)(fps * 1.0);
        int maxRun = Math.Max(1, (int)(fps * .16));
        double[] adjacent = new double[count];
        for (int i = 1; i < count; i++) adjacent[i] = Distance(data, i - 1, i);
        var found = new List<Episode>();
        for (int first = maxLag; first < count - 1; first++)
        {
            if (adjacent[first] < 7) continue;
            for (int last = first; last < Math.Min(first + maxRun, count - 1); last++)
            {
                double edge = Math.Min(adjacent[first], adjacent[last + 1]);
                if (edge < 7) continue;
                double bridge = Distance(data, first - 1, last + 1);
                if (bridge > edge * bridgeRatio) continue;
                double worstMatch = 0;
                int firstLag = 0;
                bool valid = true;
                for (int frame = first; frame <= last; frame++)
                {
                    double away = Math.Min(Distance(data, frame, first - 1), Distance(data, frame, last + 1));
                    if (away < 7) { valid = false; break; }
                    double best = double.MaxValue; int lag = 0;
                    for (int old = frame - maxLag; old <= Math.Min(frame - minLag, first - 2); old++)
                    {
                        double d = Distance(data, frame, old);
                        if (d < best) { best = d; lag = frame - old; }
                    }
                    if (best > 4 || best > away * .28) { valid = false; break; }
                    worstMatch = Math.Max(worstMatch, best);
                    if (frame == first) firstLag = lag;
                }
                if (!valid) continue;
                found.Add(new Episode { First = first, Last = last, Lag = firstLag,
                    Entry = adjacent[first], Exit = adjacent[last + 1], Bridge = bridge, Match = worstMatch });
                first = last;
                break;
            }
        }
        return found;
    }
    public static int Scan(string grayPath, string reportPath, double fps)
    {
        return Scan(grayPath, reportPath, fps, 1.10);
    }
    public static int Scan(string grayPath, string reportPath, double fps, double bridgeRatio)
    {
        byte[] data = File.ReadAllBytes(grayPath);
        var episodes = Detect(data, fps, bridgeRatio);
        using (var writer = new StreamWriter(reportPath, false))
        {
            writer.WriteLine("first_frame,last_frame,relative_seconds,lag_frames,entry_mae,exit_mae,bridge_mae,match_mae");
            foreach (var e in episodes)
                writer.WriteLine(string.Format(CultureInfo.InvariantCulture,
                    "{0},{1},{2:F3},{3},{4:F3},{5:F3},{6:F3},{7:F3}",
                    e.First, e.Last, e.First / fps, e.Lag, e.Entry, e.Exit, e.Bridge, e.Match));
        }
        return episodes.Count;
    }
    public static string SelfTest()
    {
        byte[] clean = new byte[500 * Size];
        // A continuous moving texture followed by a lasting scene cut.
        for (int n = 0; n < 500; n++)
            for (int y = 0; y < Height; y++)
                for (int x = 0; x < Width; x++)
                    clean[n * Size + y * Width + x] = (byte)(125 + 85 * Math.Sin(x * .13 + y * .08 + n * .12 + (n >= 350 ? 2 : 0)));
        if (Detect(clean, 50).Count != 0) throw new Exception("False positive on clean motion/scene cut");
        byte[] damaged = (byte[])clean.Clone();
        int[] starts = { 100, 200, 300 }, lengths = { 1, 2, 6 };
        for (int j = 0; j < starts.Length; j++)
            for (int k = 0; k < lengths[j]; k++)
                Buffer.BlockCopy(clean, (starts[j] + k - 24) * Size, damaged, (starts[j] + k) * Size, Size);
        var episodes = Detect(damaged, 50);
        if (episodes.Count != starts.Length) throw new Exception("Missed synthetic flash");
        for (int j = 0; j < starts.Length; j++)
            if (episodes[j].First != starts[j] || episodes[j].Last != starts[j] + lengths[j] - 1)
                throw new Exception("Incorrect synthetic flash boundary");
        return "Passed: clean motion, lasting scene cut, and injected 1/2/6-frame stale flashes.";
    }

    public static string VerifyRepair(string sourceGrayPath, string repairedGrayPath, string episodeCsv)
    {
        byte[] source = File.ReadAllBytes(sourceGrayPath), repaired = File.ReadAllBytes(repairedGrayPath);
        if (source.Length != repaired.Length || source.Length % Size != 0)
            throw new InvalidDataException("Repaired frame count differs from source");
        int count = source.Length / Size;
        var replacement = new Dictionary<int, int>();
        foreach (string row in File.ReadLines(episodeCsv))
        {
            if (row.TrimStart('"').StartsWith("first_frame")) continue;
            string[] fields = row.Split(',');
            int first = int.Parse(fields[0].Trim('"'), CultureInfo.InvariantCulture);
            int last = int.Parse(fields[1].Trim('"'), CultureInfo.InvariantCulture);
            for (int n = first; n <= last; n++) replacement.Add(n, first - 1);
        }
        double total = 0, maximum = 0; int maximumFrame = -1, largeErrors = 0, failedReplacement = 0;
        for (int n = 0; n < count; n++)
        {
            int expected = n;
            bool replaced = replacement.TryGetValue(n, out expected);
            if (!replaced) expected = n;
            long expectedError = 0, originalError = 0;
            for (int y = 3; y < Height - 3; y++)
                for (int x = 3; x < Width - 3; x++)
                {
                    int pixel = y * Width + x;
                    expectedError += Math.Abs((int)repaired[n * Size + pixel] - source[expected * Size + pixel]);
                    if (replaced) originalError += Math.Abs((int)repaired[n * Size + pixel] - source[n * Size + pixel]);
                }
            double mae = expectedError / (double)((Height - 6) * (Width - 6));
            total += mae;
            if (mae > maximum) { maximum = mae; maximumFrame = n; }
            if (mae > 5) largeErrors++;
            if (replaced && expectedError >= originalError) failedReplacement++;
        }
        return string.Format(CultureInfo.InvariantCulture,
            "Frames={0}\nReplacedFrames={1}\nMeanExpectedMAE={2:F6}\nMaxExpectedMAE={3:F6}\nMaxErrorFrame={4}\nFramesWithMAEAbove5={5}\nReplacementsNotCloserToExpected={6}\n",
            count, replacement.Count, total / count, maximum, maximumFrame, largeErrors, failedReplacement);
    }
}
