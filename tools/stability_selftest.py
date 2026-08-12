from backend.faceswap_engine import FaceSwapEngine


def main():
    assert abs(FaceSwapEngine._iou([0,0,100,100],[0,0,100,100]) - 1.0) < 1e-6
    assert FaceSwapEngine._iou([0,0,10,10],[20,20,30,30]) == 0.0
    d = FaceSwapEngine._center_distance_norm([0,0,10,10],[0,0,10,10],100,100)
    assert d == 0.0
    print('stability selftest OK')

if __name__ == '__main__':
    main()
