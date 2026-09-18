import { Overlay } from "@/components/Overlay";

export default async function OverlayPage({
  params,
}: {
  params: Promise<{ handle: string }>;
}) {
  const { handle } = await params;
  return <Overlay handle={decodeURIComponent(handle)} />;
}
